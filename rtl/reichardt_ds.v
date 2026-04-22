`timescale 1ns/1ps
`default_nettype none

// 8-direction Reichardt detector: correlates delayed/undelayed pairs to estimate direction.
// Uses leaky integration to prevent accumulator overflow and allow adaptation.
//
// DIRECTION ENCODING:
// - dir_x: positive = East, negative = West
// - dir_y: positive = North, negative = South
// - Diagonal inputs contribute to both axes with scaled weights
//
// DIAGONAL CONTRIBUTION:
// - NE: +X, +Y (scaled by DIAG_INCR for geometric correctness)
// - NW: -X, +Y
// - SE: +X, -Y
// - SW: -X, -Y
module reichardt_ds #(
    parameter XW=10, YW=10, CW=8,
    parameter DECAY_SHIFT=4  // Decay rate: acc = acc - (acc >>> DECAY_SHIFT) each cycle
)(
    input  wire clk, rst,
    // Cardinal direction taps
    input  wire v_e, v_w, v_n, v_s,
    // Diagonal direction taps
    input  wire v_ne, v_nw, v_se, v_sw,
    input  wire in_valid,                // current event valid
    output wire out_valid,
    output reg signed [CW-1:0] dir_x = {CW{1'b0}},    // + => East, - => West
    output reg signed [CW-1:0] dir_y = {CW{1'b0}}     // + => North, - => South
);
    // Internal registered valid, gated with !rst for immediate reset response
    reg out_valid_int = 1'b0;
    assign out_valid = out_valid_int && !rst;
    // Extended precision accumulators to handle decay arithmetic
    reg signed [CW+3:0] acc_x, acc_y;

    // Decay term (leaky integrator)
    wire signed [CW+3:0] decay_x = acc_x >>> DECAY_SHIFT;
    wire signed [CW+3:0] decay_y = acc_y >>> DECAY_SHIFT;

    // Correlation increment from directional taps (properly sized to CW+4 bits)
    // Cardinal directions use full weight (+8)
    // Diagonal directions use scaled weight (+6 ≈ 8 * 0.707) for geometric correctness
    localparam signed [CW+3:0] CARD_INCR = {{(CW){1'b0}}, 4'sd8};  // +8 for cardinal
    localparam signed [CW+3:0] DIAG_INCR = {{(CW){1'b0}}, 4'sd6};  // +6 for diagonal (≈ 8/sqrt(2))
    localparam signed [CW+3:0] ZERO_VAL  = {(CW+4){1'b0}};

    // DIRECTION CONVENTION NOTE:
    // delay_lattice_rb uses the "photoreceptor source" convention:
    //   v_e fires when delayed event was at x+1 and current is at x
    //       = target moved FROM x+1 TO x = target moved WEST (decreasing x)
    //   v_w fires when delayed event was at x-1 and current is at x
    //       = target moved FROM x-1 TO x = target moved EAST (increasing x)
    // Similarly: v_n fires for South-moving targets, v_s for North-moving.
    // Diagonals are also inverted: v_sw fires for NE motion, v_ne for SW, etc.
    // The formulas below correct for this inversion so that:
    //   dir_x > 0  ==> target moving East  (increasing x)
    //   dir_x < 0  ==> target moving West  (decreasing x)
    //   dir_y > 0  ==> target moving North (increasing y)
    //   dir_y < 0  ==> target moving South (decreasing y)

    // Cardinal contributions to X axis (corrected signs)
    wire signed [CW+3:0] card_x = (v_w ? CARD_INCR : ZERO_VAL) - (v_e ? CARD_INCR : ZERO_VAL);
    // Cardinal contributions to Y axis (corrected signs)
    wire signed [CW+3:0] card_y = (v_s ? CARD_INCR : ZERO_VAL) - (v_n ? CARD_INCR : ZERO_VAL);

    // Diagonal (corrected): v_sw fires for NE, v_nw for SE, v_se for NW, v_ne for SW
    // NE motion (+X, +Y): v_sw fires
    // SE motion (+X, -Y): v_nw fires
    // NW motion (-X, +Y): v_se fires
    // SW motion (-X, -Y): v_ne fires
    wire signed [CW+3:0] diag_x = (v_sw ? DIAG_INCR : ZERO_VAL) + (v_nw ? DIAG_INCR : ZERO_VAL)
                                - (v_se ? DIAG_INCR : ZERO_VAL) - (v_ne ? DIAG_INCR : ZERO_VAL);
    wire signed [CW+3:0] diag_y = (v_sw ? DIAG_INCR : ZERO_VAL) + (v_se ? DIAG_INCR : ZERO_VAL)
                                - (v_nw ? DIAG_INCR : ZERO_VAL) - (v_ne ? DIAG_INCR : ZERO_VAL);

    // Total increment combining cardinal and diagonal
    wire signed [CW+3:0] incr_x = card_x + diag_x;
    wire signed [CW+3:0] incr_y = card_y + diag_y;

    // Saturation bounds — declared at the accumulator width (CW+4) so comparisons
    // against the (CW+4)-bit 'val' argument are width-homogeneous (no WIDTHEXPAND).
    localparam signed [CW+3:0] SAT_MAX_W = {{4{1'b0}}, 1'b0, {(CW-1){1'b1}}};  // +127 sign-extended
    localparam signed [CW+3:0] SAT_MIN_W = {{4{1'b1}}, 1'b1, {(CW-1){1'b0}}};  // -128 sign-extended

    // Saturating output function
    function signed [CW-1:0] saturate;
        input signed [CW+3:0] val;
        begin
            if (val > SAT_MAX_W)
                saturate = SAT_MAX_W[CW-1:0];
            else if (val < SAT_MIN_W)
                saturate = SAT_MIN_W[CW-1:0];
            else
                saturate = val[CW-1:0];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            out_valid_int <= 1'b0;
            dir_x <= {CW{1'b0}};
            dir_y <= {CW{1'b0}};
            acc_x <= {(CW+4){1'b0}};
            acc_y <= {(CW+4){1'b0}};
        end else begin
            out_valid_int <= 1'b0;

            // Apply decay every cycle (leaky integration)
            acc_x <= acc_x - decay_x;
            acc_y <= acc_y - decay_y;

            // On valid event, add correlation and output
            if (in_valid) begin
                acc_x <= acc_x - decay_x + incr_x;
                acc_y <= acc_y - decay_y + incr_y;
                // Output saturated direction estimate
                dir_x <= saturate(acc_x - decay_x + incr_x);
                dir_y <= saturate(acc_y - decay_y + incr_y);
                out_valid_int <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
