`timescale 1ns/1ps
`default_nettype none

// Burst gate: passes valid only when event density exceeds threshold in a sliding window.
// Uses hysteresis to prevent output chatter at threshold boundary.
//
// WINDOW SEMANTICS:
// - Window spans WINDOW cycles, numbered 0 to WINDOW-1
// - Events arriving during the window are counted (inclusive of boundary cycle)
// - At end of window (win_cnt == WINDOW-1):
//   - Gate decision uses final ev_cnt (including any event this cycle)
//   - Counters reset for next window
// - An event arriving at the window boundary IS counted in the CURRENT window,
//   then counters reset for the next window (boundary event counts in old window)
//
// HYSTERESIS:
// - TH_OPEN: threshold to open gate (requires sustained activity)
// - TH_CLOSE: threshold to close gate (lower, allows brief gaps)
// - Prevents rapid on/off toggling at threshold boundary
//
// BACKWARD COMPATIBILITY:
// - COUNT_TH parameter is supported for legacy testbenches
// - If COUNT_TH >= 0, it overrides TH_OPEN and TH_CLOSE (no hysteresis)
// - Set COUNT_TH = -1 (default) to use hysteresis with TH_OPEN/TH_CLOSE
//
// OUTPUT TIMING:
// - out_valid asserts in the same cycle as in_valid when gate is open
// - No pipeline delay: immediate pass-through gating
module burst_gate #(
    parameter WINDOW=16,
    parameter COUNT_TH=-1,  // Legacy parameter: if >= 0, overrides TH_OPEN/TH_CLOSE
    parameter TH_OPEN=3,    // Threshold to open gate (higher)
    parameter TH_CLOSE=1    // Threshold to close gate (lower)
)(
    input  wire clk, rst,
    input  wire in_valid,
    output wire out_valid
);
    // Internal registered valid, gated with !rst for immediate reset response
    reg out_valid_int = 1'b0;
    assign out_valid = out_valid_int && !rst;
    // win_cnt must be wide enough to count to WINDOW-1 without wrapping.
    // Use 32 bits to support WINDOW up to 2^32 (covers any practical WINDOW).
    reg [31:0] win_cnt;
    reg [7:0]  ev_cnt;
    reg gate_state;  // Hysteresis state: 1 = gate open, 0 = gate closed

    // Backward compatibility: if COUNT_TH >= 0, use it for both thresholds (no hysteresis)
    localparam USE_LEGACY = (COUNT_TH >= 0);
    localparam [7:0] THRESH_OPEN  = USE_LEGACY ? COUNT_TH : TH_OPEN;
    localparam [7:0] THRESH_CLOSE = USE_LEGACY ? COUNT_TH : TH_CLOSE;

    // Window boundary detection
    wire window_end = (win_cnt == WINDOW-1);

    // Compute next event count: increment if valid event and not saturated
    // This happens BEFORE the window reset check
    wire [7:0] ev_cnt_incr = (in_valid && ev_cnt < 8'd255) ? (ev_cnt + 8'd1) : ev_cnt;

    // Final event count for this window (used for gating decision)
    // At window boundary, this includes any event arriving this cycle
    wire [7:0] ev_cnt_final = ev_cnt_incr;

    // Hysteresis logic: different thresholds for opening vs closing
    // When gate is closed, need THRESH_OPEN to open
    // When gate is open, only close if below THRESH_CLOSE
    wire should_open  = (ev_cnt_final >= THRESH_OPEN);
    wire should_close = (ev_cnt_final < THRESH_CLOSE);
    wire gate_next = gate_state ? ~should_close : should_open;

    // Gate passes event based on hysteresis state:
    // - If gate was open (gate_state=1): stay open unless should_close
    // - If gate was closed (gate_state=0): only open if should_open
    wire gate_open = gate_state ? ~should_close : should_open;

    // Next state computation with mutual exclusivity
    wire [31:0] win_cnt_next = window_end ? 32'd0 : (win_cnt + 32'd1);
    wire [7:0]  ev_cnt_next  = window_end ? 8'd0  : ev_cnt_incr;

    always @(posedge clk) begin
        if (rst) begin
            win_cnt <= 32'd0;
            ev_cnt <= 8'd0;
            gate_state <= 1'b0;
            out_valid_int <= 1'b0;
        end else begin
            // Update counters (single assignment per register)
            win_cnt <= win_cnt_next;
            ev_cnt <= ev_cnt_next;

            // Update gate state at window boundary with hysteresis
            if (window_end) begin
                gate_state <= gate_next;
            end

            // Gate output: pass valid when gate is open
            out_valid_int <= in_valid && gate_open;
        end
    end
endmodule

`default_nettype wire
