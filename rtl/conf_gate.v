`timescale 1ns/1ps
`default_nettype none

// Confidence gate: computes confidence score from activity rate + direction magnitude.
// Output saturates at 255 to prevent overflow.
//
// WINDOW SEMANTICS:
// - Window spans WINDOW cycles, numbered 0 to WINDOW-1
// - Events arriving during the window are counted (inclusive of boundary cycle)
// - At end of window (win_cnt == WINDOW-1):
//   - Confidence is computed from final ev_cnt (including any event this cycle)
//   - out_valid pulses for one cycle with the computed confidence
//   - Counters reset for next window
//
// CONFIDENCE FORMULA:
// - conf = saturate_8bit(ev_cnt_final * 8 + (|dir_x| + |dir_y|) / 2)
// - Higher event count -> higher confidence (activity-based)
// - Higher direction magnitude -> higher confidence (motion coherence)
module conf_gate #(
    parameter WINDOW=16
)(
    input  wire clk, rst,
    input  wire in_valid,
    input  wire signed [7:0] dir_x,
    input  wire signed [7:0] dir_y,
    output wire out_valid,
    output reg  [7:0] conf = 8'b0
);
    // Internal registered valid, gated with !rst for immediate reset response
    reg out_valid_int = 1'b0;
    assign out_valid = out_valid_int && !rst;

    reg [7:0] win_cnt;
    reg [7:0] ev_cnt;

    // Window boundary detection
    wire window_end = (win_cnt == WINDOW-1);

    // Absolute value of direction components (safe two's complement)
    wire [7:0] dx_abs = dir_x[7] ? (~dir_x + 8'd1) : dir_x;
    wire [7:0] dy_abs = dir_y[7] ? (~dir_y + 8'd1) : dir_y;
    wire [7:0] vmag = (dx_abs + dy_abs) >> 1;

    // Compute event count including any event this cycle
    wire [7:0] ev_cnt_incr = (in_valid && ev_cnt < 8'd255) ? (ev_cnt + 8'd1) : ev_cnt;

    // Final event count for confidence computation
    wire [7:0] ev_cnt_final = ev_cnt_incr;

    // Extended precision for confidence calculation to detect overflow
    wire [10:0] ev_scaled = {3'b0, ev_cnt_final} << 3;  // ev_cnt * 8
    wire [10:0] conf_raw = ev_scaled + {3'b0, vmag};

    // Saturate to 8-bit max
    wire [7:0] conf_sat = (conf_raw > 11'd255) ? 8'd255 : conf_raw[7:0];

    // Next state computation with mutual exclusivity
    wire [7:0] win_cnt_next = window_end ? 8'd0 : (win_cnt + 8'd1);
    wire [7:0] ev_cnt_next  = window_end ? 8'd0 : ev_cnt_incr;

    always @(posedge clk) begin
        if (rst) begin
            win_cnt <= 8'd0;
            ev_cnt <= 8'd0;
            conf <= 8'd0;
            out_valid_int <= 1'b0;
        end else begin
            // Update counters (single assignment per register)
            win_cnt <= win_cnt_next;
            ev_cnt <= ev_cnt_next;

            // Output confidence at window boundary
            if (window_end) begin
                conf <= conf_sat;
                out_valid_int <= 1'b1;
            end else begin
                out_valid_int <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
