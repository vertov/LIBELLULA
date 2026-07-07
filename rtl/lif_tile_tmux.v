`timescale 1ns/1ps
`default_nettype none

// Time-multiplexed LIF array (leaky integrate-and-fire). Explicit 2-stage pipeline.
// Stage 0: Capture scan address and hit flag, initiate read
// Stage 1: Compute next state from read value, write back, detect spike
//
// Events are hashed into neuron addresses. If an event arrives when its hashed
// address is not currently selected by the scan, the LIF immediately services
// that neuron by retiming the scan for one cycle.
//
// -------------------------------------------------------------------------
// SCAN / LEAK NOTE (fix/pipeline-rework):
// Membrane leak only occurs when a neuron is READ, and reads are driven by the
// scan address. Previously the scan was ALWAYS the external `scan_addr` input,
// so the leak time-constant of the whole front end was an implicit contract on
// the host (how fast it swept scan_addr) rather than a property of this module.
// With SCAN_MODE=1 an internal free-running counter drives the background scan,
// so every neuron is visited every 2^AW cycles and the leak cadence is well
// defined and self-contained. SCAN_MODE=0 (default) preserves the original
// externally-driven behaviour so existing unit testbenches are unchanged.
// The top-level SoC instantiates with SCAN_MODE=1.
// -------------------------------------------------------------------------
module lif_tile_tmux #(
    parameter XW=10, YW=10,              // address widths
    parameter AW=10,                     // addressable depth (X or Y flatten)
    parameter SW=14,                     // state width (leaky membrane)
    parameter LEAK_SHIFT=4,              // leak factor: state -= state>>LEAK_SHIFT
    parameter THRESH=16,                 // firing threshold
    parameter integer HIT_WEIGHT=1,      // charge per hit
    parameter SCAN_MODE=0                // 0 = external scan_addr; 1 = internal free-running scan
)(
    input  wire          clk, rst,
    input  wire          in_valid,
    input  wire [XW-1:0] in_x,
    input  wire [YW-1:0] in_y,
    input  wire          in_pol,
    input  wire [AW-1:0] scan_addr,      // used only when SCAN_MODE=0
    output wire          out_valid,
    output reg  [XW-1:0] out_x = {XW{1'b0}},
    output reg  [YW-1:0] out_y = {YW{1'b0}},
    output reg           out_pol = 1'b0,
    output reg  [XW-1:0] out_ex = {XW{1'b0}},
    output reg  [YW-1:0] out_ey = {YW{1'b0}}
);
    reg out_valid_int = 1'b0;
    assign out_valid = out_valid_int && !rst;

    reg [SW-1:0] state_mem [0:(1<<AW)-1];

    localparam HX = AW / 2;
    localparam HY = AW - HX;
    wire [AW-1:0] hashed_xy = {in_x[XW-1:XW-HX], in_y[YW-1:YW-HY]};

    // Internal free-running scan counter (SCAN_MODE=1). Visits every neuron
    // once per 2^AW cycles, giving a well-defined background leak cadence.
    reg [AW-1:0] int_scan_addr = {AW{1'b0}};
    wire [AW-1:0] eff_scan = SCAN_MODE ? int_scan_addr : scan_addr;

`ifdef LIBELLULA_DIAG
    (* keep, syn_keep *) reg [31:0] events_presented = 32'd0;
    (* keep, syn_keep *) reg [31:0] events_accepted  = 32'd0;
    (* keep, syn_keep *) reg [31:0] events_retimed   = 32'd0;
    (* keep, syn_keep *) reg [31:0] lif_updates      = 32'd0;
    (* keep, syn_keep *) reg [31:0] lif_spikes       = 32'd0;
`else
    wire [31:0] events_presented = 32'd0;
    wire [31:0] events_accepted  = 32'd0;
    wire [31:0] events_retimed   = 32'd0;
    wire [31:0] lif_updates      = 32'd0;
    wire [31:0] lif_spikes       = 32'd0;
`endif

    wire event_pending = in_valid;
    wire [AW-1:0] scan_addr_target = event_pending ? hashed_xy : eff_scan;
    wire retime_event = in_valid && (hashed_xy != eff_scan);

    reg [AW-1:0] scan_addr_s1;
    reg          hit_s1;
    reg [XW-1:0] x_s1;
    reg [YW-1:0] y_s1;
    reg          pol_s1;

    // Sequential reset counter: clears one state_mem cell per clock cycle
    // during reset. After 2^AW cycles of asserted reset all cells are zero.
    reg [AW-1:0] rst_clear_addr = {AW{1'b0}};

    wire [SW-1:0] st_read = state_mem[scan_addr_s1];
    wire [SW-1:0] leak_amount = st_read >> LEAK_SHIFT;
    wire [SW-1:0] st_after_leak = st_read - leak_amount;
    localparam integer HIT_INC_I = (HIT_WEIGHT > (1<<SW)-1) ? (1<<SW)-1 : HIT_WEIGHT;
    wire [SW:0] st_sum = {1'b0, st_after_leak} +
                         (hit_s1 ? HIT_INC_I[SW:0] : {(SW+1){1'b0}});
    wire [SW-1:0] st_next = st_sum[SW] ? {SW{1'b1}} : st_sum[SW-1:0];
    wire spike = (st_next >= THRESH);
    wire [SW-1:0] st_writeback = spike ? {SW{1'b0}} : st_next;

    integer i;
    initial begin
        for (i = 0; i < (1 << AW); i = i + 1) begin
            state_mem[i] = {SW{1'b0}};
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            state_mem[rst_clear_addr] <= {SW{1'b0}};
            rst_clear_addr            <= rst_clear_addr + 1'b1;

            int_scan_addr <= {AW{1'b0}};
            scan_addr_s1 <= {AW{1'b0}};
            hit_s1 <= 1'b0;
            x_s1 <= {XW{1'b0}};
            y_s1 <= {YW{1'b0}};
            pol_s1 <= 1'b0;
            out_valid_int <= 1'b0;
            out_x <= {XW{1'b0}};
            out_y <= {YW{1'b0}};
            out_pol <= 1'b0;
            out_ex <= {XW{1'b0}};
            out_ey <= {YW{1'b0}};
`ifdef LIBELLULA_DIAG
            events_presented <= 32'd0;
            events_accepted  <= 32'd0;
            events_retimed   <= 32'd0;
            lif_updates      <= 32'd0;
            lif_spikes       <= 32'd0;
`endif
        end else begin
            rst_clear_addr <= {AW{1'b0}};   // reset the counter for next rst pulse
            // Advance internal background scan (only meaningful when SCAN_MODE=1)
            int_scan_addr <= int_scan_addr + 1'b1;
`ifdef LIBELLULA_DIAG
            if (in_valid)
                events_presented <= events_presented + 32'd1;
            if (in_valid) begin
                events_accepted <= events_accepted + 32'd1;
                if (retime_event)
                    events_retimed <= events_retimed + 32'd1;
            end
            lif_updates <= lif_updates + 32'd1;
`endif
            scan_addr_s1 <= scan_addr_target;
            hit_s1 <= event_pending;
            x_s1 <= in_x;
            y_s1 <= in_y;
            pol_s1 <= in_pol;

            state_mem[scan_addr_s1] <= st_writeback;

            out_valid_int <= spike;
            if (spike) begin
                out_x  <= {{(XW-HX){1'b0}}, scan_addr_s1[AW-1:AW-HX]};
                out_y  <= {{(YW-HY){1'b0}}, scan_addr_s1[HY-1:0]};
                out_pol <= pol_s1;
                out_ex <= x_s1;
                out_ey <= y_s1;
`ifdef LIBELLULA_DIAG
                lif_spikes <= lif_spikes + 32'd1;
`endif
            end
        end
    end
endmodule

`default_nettype wire
