// =============================================================================
// libellula_soc.v
// LIBELLULA Core v22  —  AXI4-Stream SoC Integration Wrapper
//
// Self-contained plug-in IP for AXI4-S SoC fabrics (Xilinx/AMD, Intel/Altera).
// Packages the full LIBELLULA tracking pipeline with:
//   • AXI4-S slave input   (32-bit, 100 Meps design-intent at 200 MHz)
//   • AXI4-S master output (64-bit, includes track_id for multi-target)
//   • Internal scan counter (no external scan pin required)
//   • Active-low rst_n boundary (ARM IHI 0051A convention)
//   • UAV intercept defaults (10–25 m/s, 640×480 DVS sensor)
//
// UAV parameter rationale:
//   DW=6            64-event ring buffer; dense bursts → reliable direction detect
//   LIF_LEAK_SHIFT=14  99.99% membrane retention per scan cycle (0.2–1 ms buckets)
//   LIF_THRESH=4    hair-trigger; one strong event fires the neuron
//   LIF_HIT_WEIGHT=8192  large charge deposit ensures THRESH=4 is crossed immediately
//   BG_WINDOW_OVR=4  short density gate; opens within first burst window
//   BG_TH_OPEN=1    gate opens on first correlated event
//   NTRACK=4        four independent α-β trackers (multi-target)
//
// Output TDATA (64-bit, little-endian fields):
//   [63:48]  16'b0        reserved / zero
//   [47:46]   track_id    which tracker fired (0–3)
//   [45:40]    6'b0       reserved / zero
//   [39:32]    conf       confidence byte
//   [31:16]    y_hat      Q8.8 Y prediction
//   [15: 0]    x_hat      Q8.8 X prediction
//
// TKEEP = 8'hFF (all 8 bytes declared valid; upper 2 are reserved-zero).
// TLAST = TVALID (one AXI4-S frame per prediction event).
//
// Throughput:
//   Input  : 100 Meps design intent (one event per 2 clocks; bridge FSM bound).
//            Validated envelope: 1 Meps zero-drop (tb_aer_throughput_1meps).
//   Output : back-pressured, depth-4 FIFO; no prediction dropped unless all
//            4 tracker slots fire simultaneously AND downstream holds TREADY=0
//            for more than 4 consecutive output cycles.
//
// Reset:
//   rst_n is active-low at the AXI boundary.  libellula_top uses active-high rst
//   internally; this wrapper inverts rst_n → rst for the core.
//
// Scan address:
//   Generated internally as a free-running AW-bit counter.  The counter cycles
//   through all 2^AW tile addresses every 2^AW clocks (~1.28 µs for AW=8 at
//   200 MHz), giving each LIF neuron one scan opportunity per period.
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module libellula_soc #(
    // ---- sensor / pipeline geometry (change together as a matched set) ----
    parameter XW     = 10,   // pixel X address width
    parameter YW     = 10,   // pixel Y address width
    parameter AW     =  8,   // tile address width (2^AW LIF neurons)
    parameter PW     = 16,   // prediction coordinate width (Q8.8)
    parameter DATA_W = 32,   // AXI4-S input TDATA width

    // ---- delay lattice ----
    parameter DW     =  6,   // ring buffer depth = 2^DW (UAV: 64 events)

    // ---- multi-target pool ----
    parameter NTRACK        = 4,   // number of independent α-β trackers
    parameter ASSIGN_TH     = 96,  // L1 assignment threshold (pixels)
    parameter COAST_TIMEOUT = 4,   // missed-update coast count before retirement

    // ---- LIF neuron tuning ----
    parameter integer LIF_LEAK_SHIFT = 14,   // 99.99% retention per scan cycle
    parameter integer LIF_THRESH     =  4,   // hair-trigger threshold
    parameter integer LIF_HIT_WEIGHT = 8192, // large charge for immediate fire

    // ---- burst gate tuning ----
    parameter integer BG_TH_OPEN    = 1,  // open on first correlated event
    parameter integer BG_TH_CLOSE   = 0,  // stay open once opened
    parameter integer BG_WINDOW_OVR = 4,  // short density window (4 scan periods)

    // ---- output prediction FIFO ----
    // Depth must be a power of 2 and >= NTRACK to guarantee no prediction is
    // dropped during a simultaneous multi-tracker burst.
    parameter FIFO_DEPTH = 4
)(
    input  wire        clk,
    input  wire        rst_n,   // active-low reset (AXI convention)

    // -------------------------------------------------------------------------
    // AXI4-Stream slave  (DVS event stream in)
    // -------------------------------------------------------------------------
    input  wire                  s_axis_tvalid,
    output wire                  s_axis_tready,
    input  wire [DATA_W-1:0]     s_axis_tdata,
    input  wire [(DATA_W/8)-1:0] s_axis_tkeep,   // accepted, ignored
    input  wire                  s_axis_tlast,   // accepted, ignored

    // -------------------------------------------------------------------------
    // AXI4-Stream master  (prediction stream out, 64-bit)
    // -------------------------------------------------------------------------
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire [63:0] m_axis_tdata,
    output wire [7:0]  m_axis_tkeep,   // 8'hFF (all 8 bytes valid)
    output wire        m_axis_tlast    // high when tvalid (single-beat frame)
);

    // -------------------------------------------------------------------------
    // Internal reset (active-high for libellula_top and the input bridge)
    // -------------------------------------------------------------------------
    wire rst = ~rst_n;

    // -------------------------------------------------------------------------
    // Scan address counter
    // Free-running AW-bit counter; drives lif_tile_tmux scan input.
    // -------------------------------------------------------------------------
    reg [AW-1:0] scan_addr = {AW{1'b0}};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) scan_addr <= {AW{1'b0}};
        else        scan_addr <= scan_addr + 1'b1;
    end

    // -------------------------------------------------------------------------
    // AXI4-Stream input bridge
    // -------------------------------------------------------------------------
    wire           aer_req, aer_ack;
    wire [XW-1:0]  aer_x;
    wire [YW-1:0]  aer_y;
    wire           aer_pol;

    axi4s_to_aer #(
        .XW    (XW),
        .YW    (YW),
        .DATA_W(DATA_W)
    ) u_in (
        .clk          (clk),
        .rst_n        (rst_n),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tdata (s_axis_tdata),
        .s_axis_tkeep (s_axis_tkeep),
        .s_axis_tlast (s_axis_tlast),
        .aer_req      (aer_req),
        .aer_ack      (aer_ack),
        .aer_x        (aer_x),
        .aer_y        (aer_y),
        .aer_pol      (aer_pol)
    );

    // -------------------------------------------------------------------------
    // LIBELLULA tracking core (v22, UAV profile)
    // -------------------------------------------------------------------------
    wire           pred_valid;
    wire [PW-1:0]  x_hat, y_hat;
    wire [7:0]     conf;
    wire           conf_valid;
    wire [1:0]     track_id;

    libellula_top #(
        .XW           (XW),
        .YW           (YW),
        .AW           (AW),
        .DW           (DW),
        .PW           (PW),
        .TILE_STEP    (1),
        .NTRACK       (NTRACK),
        .ASSIGN_TH    (ASSIGN_TH),
        .COAST_TIMEOUT(COAST_TIMEOUT),
        .LIF_LEAK_SHIFT(LIF_LEAK_SHIFT),
        .LIF_THRESH   (LIF_THRESH),
        .LIF_HIT_WEIGHT(LIF_HIT_WEIGHT),
        .BG_TH_OPEN   (BG_TH_OPEN),
        .BG_TH_CLOSE  (BG_TH_CLOSE),
        .BG_WINDOW_OVR(BG_WINDOW_OVR)
    ) u_core (
        .clk       (clk),
        .rst       (rst),
        .aer_req   (aer_req),
        .aer_ack   (aer_ack),
        .aer_x     (aer_x),
        .aer_y     (aer_y),
        .aer_pol   (aer_pol),
        .scan_addr (scan_addr),
        .pred_valid(pred_valid),
        .x_hat     (x_hat),
        .y_hat     (y_hat),
        .conf      (conf),
        .conf_valid(conf_valid),
        .track_id  (track_id)
    );

    // -------------------------------------------------------------------------
    // Output prediction FIFO
    // 64-bit TDATA: [63:48]=0, [47:46]=track_id, [45:40]=0, [39:32]=conf,
    //               [31:16]=y_hat, [15:0]=x_hat.
    // Depth FIFO_DEPTH (default 4); no prediction dropped when NTRACK<=FIFO_DEPTH
    // and downstream asserts TREADY within FIFO_DEPTH output cycles.
    // -------------------------------------------------------------------------
    localparam FIFO_AW = $clog2(FIFO_DEPTH);

    assign m_axis_tkeep = 8'hFF;
    assign m_axis_tlast = m_axis_tvalid;

    wire [63:0] pred_packed = {16'd0, track_id[1:0], 6'd0,
                               conf[7:0], y_hat[PW-1:0], x_hat[PW-1:0]};

    reg [63:0]      fifo_mem [0:FIFO_DEPTH-1];
    reg [FIFO_AW:0] wr_ptr = {(FIFO_AW+1){1'b0}};
    reg [FIFO_AW:0] rd_ptr = {(FIFO_AW+1){1'b0}};

    wire fifo_empty = (wr_ptr == rd_ptr);
    wire fifo_full  = (wr_ptr[FIFO_AW] != rd_ptr[FIFO_AW]) &&
                      (wr_ptr[FIFO_AW-1:0] == rd_ptr[FIFO_AW-1:0]);

    reg        out_valid = 1'b0;
    reg [63:0] out_data  = 64'd0;

    assign m_axis_tvalid = out_valid;
    assign m_axis_tdata  = out_data;

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_data  <= 64'd0;
            wr_ptr    <= {(FIFO_AW+1){1'b0}};
            rd_ptr    <= {(FIFO_AW+1){1'b0}};
            for (k = 0; k < FIFO_DEPTH; k = k + 1)
                fifo_mem[k] <= 64'd0;
        end else begin
            // Step 1: update output register
            if (out_valid && m_axis_tready) begin
                if (!fifo_empty) begin
                    out_data  <= fifo_mem[rd_ptr[FIFO_AW-1:0]];
                    out_valid <= 1'b1;
                    rd_ptr    <= rd_ptr + 1'b1;
                end else if (pred_valid) begin
                    out_data  <= pred_packed;
                    out_valid <= 1'b1;
                end else begin
                    out_valid <= 1'b0;
                end
            end else if (!out_valid && pred_valid) begin
                out_data  <= pred_packed;
                out_valid <= 1'b1;
            end

            // Step 2: push to FIFO when output is occupied and can't bypass
            if (pred_valid) begin
                if ((out_valid && !m_axis_tready) ||
                    (out_valid &&  m_axis_tready && !fifo_empty)) begin
                    if (!fifo_full) begin
                        fifo_mem[wr_ptr[FIFO_AW-1:0]] <= pred_packed;
                        wr_ptr <= wr_ptr + 1'b1;
                    end
                end
            end
        end
    end

`ifdef SIMULATION
    // Warn on FIFO overflow (prediction dropped)
    always @(posedge clk) begin
        if (rst_n && pred_valid && out_valid && !m_axis_tready && fifo_full) begin
            $display("LIBELLULA_SOC WARNING: output FIFO full, prediction dropped at time %0t",
                     $time);
        end
    end

    // AXI4-S rule: TVALID must not deassert until TREADY is seen
    reg out_valid_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) out_valid_prev <= 1'b0;
        else        out_valid_prev <= out_valid;
    end
    always @(posedge clk) begin
        if (rst_n && out_valid_prev && !out_valid && !m_axis_tready) begin
            $display("LIBELLULA_SOC PROTOCOL ERROR: TVALID deasserted without TREADY at time %0t",
                     $time);
            $finish;
        end
    end
`endif

endmodule

`default_nettype wire
