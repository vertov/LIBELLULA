// =============================================================================
// axi4s_to_aer.v
// AXI4-Stream input wrapper for LIBELLULA Core v22
//
// Bridges an AXI4-Stream slave interface to LIBELLULA's synchronous AER input
// handshake (aer_req / aer_ack / aer_x / aer_y / aer_pol).  Sits between any
// upstream AXI4-Stream producer (DMA, SoC fabric, FPGA IP core) and
// libellula_top's AER event input.
//
// TDATA unpacking (DATA_W bits, little-endian field order):
//   [DATA_W-1 : XW+YW+1]  reserved / 0   (padding, ignored)
//   [XW+YW]               pol            polarity bit
//   [XW+YW-1 : XW]        aer_y          Y pixel address
//   [XW-1  : 0]           aer_x          X pixel address
//
// With the LIBELLULA default XW=YW=10 and DATA_W=32:
//   [31:21] reserved (ignored)
//   [20]    pol
//   [19:10] y
//   [ 9: 0] x
//
// Protocol: AXI4-Stream slave -> synchronous AER master
// -----------------------------------------------------
// LIBELLULA's aer_rx samples aer_req on the rising clock edge and returns
// aer_ack combinationally (ack = req && !rst) on the same cycle.  The source
// must deassert aer_req within one cycle of seeing aer_ack, otherwise
// duplicate events are generated.  This wrapper guarantees that by issuing a
// single-cycle aer_req pulse per accepted AXI4-S beat, with at least one idle
// cycle between pulses.
//
// Throughput: one event every two clocks -> 100 Meps at 200 MHz, which is 100x
// the 1 Meps worst case exercised by tb_aer_throughput_1meps.v.  If an
// upstream AXI source can sustain bursts faster than 100 Meps, instantiate a
// small FIFO on the s_axis side.
//
// Reset polarity: this module uses active-low rst_n at the AXI boundary, to
// match the existing axi4s_pred_wrapper.v convention.  libellula_top uses
// active-high rst internally; connect rst = ~rst_n (or use a shared reset
// distribution) at integration time.
//
// AXI4-Stream compliance:
//   - s_axis_tready only deasserts when the wrapper is busy issuing an AER
//     pulse; it never deasserts combinationally from tvalid.
//   - s_axis_tkeep and s_axis_tlast are accepted for spec compliance but
//     ignored (each beat is a single-event frame).
//
// Core RTL is unchanged.  Add one new testbench (tb_axi4s_to_aer.v).
// =============================================================================

`timescale 1ns/1ps

module axi4s_to_aer #(
    parameter XW     = 10,   // AER X address width (match libellula_top)
    parameter YW     = 10,   // AER Y address width (match libellula_top)
    parameter DATA_W = 32    // AXI4-Stream TDATA width (bytes = DATA_W/8)
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // -------------------------------------------------------------------------
    // AXI4-Stream slave  (connect to upstream DMA / SoC fabric)
    // -------------------------------------------------------------------------
    input  wire                    s_axis_tvalid,
    output wire                    s_axis_tready,
    input  wire [DATA_W-1:0]       s_axis_tdata,
    input  wire [(DATA_W/8)-1:0]   s_axis_tkeep,   // ignored (spec compliance)
    input  wire                    s_axis_tlast,   // ignored (spec compliance)

    // -------------------------------------------------------------------------
    // AER master  (connect directly to libellula_top AER inputs)
    // -------------------------------------------------------------------------
    output reg                     aer_req,
    input  wire                    aer_ack,        // observed only
    output reg  [XW-1:0]           aer_x,
    output reg  [YW-1:0]           aer_y,
    output reg                     aer_pol
);

    // Note: s_axis_tkeep, s_axis_tlast and aer_ack are intentionally unused.
    // They are accepted at the port for AXI4-S spec compliance and symmetry
    // with the core's AER interface.  Lint tools may flag these as dangling.

    // -------------------------------------------------------------------------
    // FSM
    //   S_IDLE : s_axis_tready = 1, aer_req = 0
    //            On (tvalid && tready) latch fields, assert aer_req, go S_REQ
    //   S_REQ  : s_axis_tready = 0, aer_req = 1 for exactly one cycle
    //            Unconditionally return to S_IDLE -> guarantees clean pulse
    // -------------------------------------------------------------------------
    localparam S_IDLE = 1'b0;
    localparam S_REQ  = 1'b1;

    reg state;

    assign s_axis_tready = (state == S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            aer_req <= 1'b0;
            aer_x   <= {XW{1'b0}};
            aer_y   <= {YW{1'b0}};
            aer_pol <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    aer_req <= 1'b0;
                    if (s_axis_tvalid) begin
                        // Unpack TDATA fields
                        aer_x   <= s_axis_tdata[XW-1:0];
                        aer_y   <= s_axis_tdata[XW+YW-1:XW];
                        aer_pol <= s_axis_tdata[XW+YW];
                        aer_req <= 1'b1;
                        state   <= S_REQ;
                    end
                end
                S_REQ: begin
                    // Single-cycle aer_req pulse -> back to idle
                    aer_req <= 1'b0;
                    state   <= S_IDLE;
                end
                default: begin
                    state   <= S_IDLE;
                    aer_req <= 1'b0;
                end
            endcase
        end
    end

`ifdef SIMULATION
    // -------------------------------------------------------------------------
    // Simulation assertions  (synthesised away in implementation)
    // -------------------------------------------------------------------------

    // 1. aer_req must never stay high for more than one consecutive cycle
    reg req_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            req_prev <= 1'b0;
        else
            req_prev <= aer_req;
    end
    always @(posedge clk) begin
        if (rst_n && req_prev && aer_req) begin
            $display("AXI4S->AER PROTOCOL ERROR: aer_req high > 1 cycle at time %0t",
                     $time);
            $finish;
        end
    end

    // 2. s_axis_tready must be low throughout S_REQ
    always @(posedge clk) begin
        if (rst_n && (state == S_REQ) && s_axis_tready) begin
            $display("AXI4S->AER PROTOCOL ERROR: tready high during S_REQ at time %0t",
                     $time);
            $finish;
        end
    end

    // 3. AXI4-S rule: tready may drop only after a transfer; this wrapper
    //    only drops tready on the cycle it accepts a beat.  Flag unexpected
    //    transitions from high to low without tvalid.
    reg tready_prev;
    reg tvalid_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tready_prev <= 1'b1;
            tvalid_prev <= 1'b0;
        end else begin
            tready_prev <= s_axis_tready;
            tvalid_prev <= s_axis_tvalid;
        end
    end
    always @(posedge clk) begin
        if (rst_n && tready_prev && !s_axis_tready && !tvalid_prev) begin
            $display("AXI4S->AER PROTOCOL ERROR: tready dropped without prior tvalid at time %0t",
                     $time);
            $finish;
        end
    end
`endif

endmodule
