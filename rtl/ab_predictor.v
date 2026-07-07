`timescale 1ns/1ps
`default_nettype none

// α-β predictor in fixed-point (Q8.8). Gains are constants for stability.
// Uses measurement input for position correction and direction for velocity hints.
//
// FIXED-POINT FORMAT: Q8.8 (8 integer bits, 8 fractional bits)
// - Position range: 0 to 255 (unsigned output)
// - Internal calculations use wider signed arithmetic
//
// SATURATION:
// - Position output is clamped to [0, 2^XW-1] to prevent wraparound
// - Velocity is saturated to prevent unbounded growth
//
// OUTLIER REJECTION:
// - Measurements with residual > OUTLIER_TH are rejected
// - Prevents bad measurements from corrupting tracking state
// - State continues to coast using velocity prediction when outlier detected
//
// FIRST-MEASUREMENT INITIALIZATION:
// - On first valid measurement after reset, state is initialized directly
//   from the measurement, bypassing outlier rejection
// - This prevents cold-start lockout when initial position is far from (0,0)
//
// PARAMETER CONSTRAINTS:
// - QW must be >= XW + 8 (need room for fractional bits)
// - PW must be >= XW (output width must fit position)
module ab_predictor #(
    parameter XW=10, YW=10, PW=16,
    parameter OUTLIER_TH=128,   // Outlier threshold in pixels (Q8.8 integer part)
    parameter VEL_INIT=0,       // Cold-start velocity magnitude in pixels/update (0=disable).
                                // On the first measurement, velocity is pre-loaded as
                                // sign(dir_x)*VEL_INIT rather than zero, cutting warm-up lag.
                                // Set to the expected tile step size (e.g. 64 for AW=8,XW=10).
    parameter VEL_SAT_MAX=64,   // Velocity saturation limit in pixels/update.
                                // Must be >= VEL_INIT. Set to 2*tile_px for headroom.
                                // Default 64 matches AW=8 (tile=64px). For AW=6 (tile=128px)
                                // use 256; for AW=10 (tile=32px) the default is sufficient.
    parameter DIR_HINT_SHIFT=10,// Reichardt direction -> velocity hint scaling.
                                // hint_px = dir_x / 2^DIR_HINT_SHIFT (see note below).
                                // Default 10 reproduces the legacy near-zero hint so
                                // existing unit tests are unchanged; the SoC overrides it.
    parameter ADAPT_GAIN=0,     // 1 = innovation-scheduled POSITION gain: when the
                                // smoothed residual magnitude is small (locked), alpha
                                // is scaled down (/2 then /4) to suppress position
                                // jitter; large residuals restore full gain for fast
                                // acquisition/manoeuvre response. Beta and the
                                // direction hint stay at full strength — scaling them
                                // shifts the ramp-tracking equilibrium and adds bias
                                // (measured in tb_ab_adaptive).
                                // 0 = fixed gains (legacy behaviour, bit-exact).
    parameter MEAS_FILT=0       // 1 = lock-gated measurement smoothing: while locked
                                // (smoothed residual < 2 px) measurements pass through
                                // a /4 EMA before the residual is formed, averaging
                                // event-position noise. Disengages automatically the
                                // moment the innovation grows (no acquisition lag).
                                // 0 = raw measurements (legacy behaviour, bit-exact).
)(
    input  wire clk, rst,
    input  wire soft_rst,       // Per-tracker reset (from tracker pool); clears state but not output regs
    input  wire in_valid,
    input  wire [XW-1:0] in_x,
    input  wire [YW-1:0] in_y,
    input  wire signed [7:0] dir_x,  // from Reichardt (signed)
    input  wire signed [7:0] dir_y,
    output wire out_valid,
    output reg [PW-1:0] x_hat = {PW{1'b0}},
    output reg [PW-1:0] y_hat = {PW{1'b0}}
);
    // Internal registered valid, gated with !rst and !soft_rst for immediate reset response
    reg out_valid_int = 1'b0;
    assign out_valid = out_valid_int && !rst && !soft_rst;

    // VEL_INIT in Q8.8: velocity magnitude for cold-start pre-load.
    // WIDTHTRUNC: VEL_INIT is a 32-bit parameter; shifting left 8 gives a 32-bit intermediate
    // which is then truncated to 24 bits.  VEL_INIT ≤ 255 so the upper 8 bits are always 0.
    /* verilator lint_off WIDTHTRUNC */
    localparam signed [23:0] VEL_INIT_Q = VEL_INIT << 8;
    /* verilator lint_on  WIDTHTRUNC */
    // Internal precision: use wider registers for Q8.8 arithmetic
    // Position in Q8.8: 8 integer bits + 8 fractional bits = 16 bits signed
    localparam QW = 24;  // Extra precision for internal calculations

    // Parameter validation (synthesis-time check)
    initial begin
        if (QW < XW + 8) begin
            $display("ERROR: ab_predictor requires QW >= XW + 8");
            $finish;
        end
        if (PW < XW) begin
            $display("ERROR: ab_predictor requires PW >= XW");
            $finish;
        end
    end

    // State: position (Q8.8) and velocity (Q8.8)
    reg signed [QW-1:0] x_q, y_q;
    reg signed [QW-1:0] vx_q, vy_q;

    // First-measurement initialization flag
    // When 0, first valid measurement initializes state directly (bypasses outlier rejection)
    reg initialized = 1'b0;

    // -----------------------------------------------------------------------
    // Reversal detection — velocity zero-crossing clamp
    // -----------------------------------------------------------------------
    // Problem: when a target reverses direction the predictor carries residual
    // velocity from the old direction.  The alpha-beta correction term corrects
    // only a fraction per update (B_GAIN = 0.25), so it takes several updates
    // to reverse a large vx_q, producing peak overshoot on the order of one
    // tile width (characterised at 26 px for AW=8).
    //
    // Fix: detect when the Reichardt direction signal flips sign between
    // consecutive measurement events.  On detection, zero the velocity base
    // before the alpha-beta update runs.  The update then builds velocity fresh
    // from the current residual and direction hint rather than fighting residual
    // momentum from the old direction.
    //
    // dir_x_prev / dir_y_prev hold the direction at the most recent measurement.
    // Updated unconditionally on every in_valid (init, outlier, and normal paths)
    // so they always track the direction at the last real measurement event.
    reg signed [7:0] dir_x_prev = 8'sd0;
    reg signed [7:0] dir_y_prev = 8'sd0;

    // Noise-floor thresholds: one Reichardt cardinal correlation unit (weight=8).
    // Both old and new direction magnitudes must exceed this threshold before a
    // sign flip is declared a reversal.  Guards against false triggers when the
    // accumulator is near zero (sparse events, scene transition, or noise).
    localparam signed [7:0] REVERSAL_TH_POS =  8'sd8;
    localparam signed [7:0] REVERSAL_TH_NEG = -8'sd8;

    // Magnitude checks — is each direction reading meaningfully above the noise floor?
    wire dir_x_cur_ok  = (dir_x      > REVERSAL_TH_POS) || (dir_x      < REVERSAL_TH_NEG);
    wire dir_x_prev_ok = (dir_x_prev > REVERSAL_TH_POS) || (dir_x_prev < REVERSAL_TH_NEG);
    wire dir_y_cur_ok  = (dir_y      > REVERSAL_TH_POS) || (dir_y      < REVERSAL_TH_NEG);
    wire dir_y_prev_ok = (dir_y_prev > REVERSAL_TH_POS) || (dir_y_prev < REVERSAL_TH_NEG);

    // Reversal conditions:
    //   1. The predictor has been initialized (dir_x_prev holds a real prior direction)
    //   2. Sign of direction has flipped since the last measurement
    //   3. Both old and new direction magnitudes are above the noise floor
    wire reversal_x = initialized
                   && (dir_x[7] != dir_x_prev[7])
                   && dir_x_cur_ok
                   && dir_x_prev_ok;
    wire reversal_y = initialized
                   && (dir_y[7] != dir_y_prev[7])
                   && dir_y_cur_ok
                   && dir_y_prev_ok;

    // Velocity base for the alpha-beta update.
    // On reversal: zero so the correction builds from scratch.
    // Otherwise: use the current accumulated velocity as normal.
    wire signed [QW-1:0] vx_base = reversal_x ? {QW{1'b0}} : vx_q;
    wire signed [QW-1:0] vy_base = reversal_y ? {QW{1'b0}} : vy_q;

    // Gains (Q0.8): alpha for position, beta for velocity
    // Higher alpha = faster position tracking, lower smoothing
    // Higher beta = faster velocity adaptation
    localparam signed [8:0] A_GAIN = 9'sd192;  // 0.75 (alpha) - fast position tracking
    localparam signed [8:0] B_GAIN = 9'sd64;   // 0.25 (beta) - moderate velocity adaptation

    // Velocity saturation bounds derived from VEL_SAT_MAX parameter (in pixels/update → Q8.8)
    // WIDTHTRUNC: 32-bit integer arithmetic truncated to QW=24 bits; values are bounded
    // (VEL_SAT_MAX ≤ 512, so VEL_SAT_Q_INT ≤ 131072, well within 24-bit signed range).
    localparam integer         VEL_SAT_Q_INT = VEL_SAT_MAX << 8;
    /* verilator lint_off WIDTHTRUNC */
    localparam signed [QW-1:0] VEL_MAX_Q     =  VEL_SAT_Q_INT;
    localparam signed [QW-1:0] VEL_MIN_Q     = -VEL_SAT_Q_INT;
    /* verilator lint_on  WIDTHTRUNC */

    // Convert measurement to Q8.8 (shift left by 8)
    // in_x is XW bits unsigned, extend to QW bits then shift
    wire signed [QW-1:0] meas_x_q = $signed({{(QW-XW-8){1'b0}}, in_x, 8'b0});
    wire signed [QW-1:0] meas_y_q = $signed({{(QW-YW-8){1'b0}}, in_y, 8'b0});

    // -----------------------------------------------------------------------
    // Innovation monitor (ADAPT_GAIN / MEAS_FILT support)
    // -----------------------------------------------------------------------
    // innov_avg is an EMA (/4) of the L1 residual magnitude, updated on every
    // ACCEPTED measurement. It is registered state, so the lock decision each
    // cycle is based on the residual history up to the PREVIOUS measurement —
    // no combinational loop with the residual computed below.
    //   innov_avg <  2 px : locked  -> minimum gain, measurement EMA engaged
    //   innov_avg <  8 px : settling-> half gain
    //   otherwise         : acquiring/manoeuvring -> full gain, raw measurements
    localparam [QW-1:0] INNOV_LO_Q = 2 << 8;   // 2 px in Q8.8
    localparam [QW-1:0] INNOV_HI_Q = 8 << 8;   // 8 px in Q8.8
    reg [QW-1:0] innov_avg = INNOV_HI_Q;       // start at full gain (acquisition)

    // Gain scheduling is gated on the direction hint being quiet. The hint
    // injects velocity every update, which the alpha correction largely
    // cancels in the output at full gain; attenuating alpha while the hint
    // is active re-exposes that bias as steady output offset (measured:
    // +4 px at 1 px/update drift in tb_px_bound_300hz). When the hint is
    // below the noise floor there is no bias to expose and gain reduction
    // is pure jitter win.
    wire hint_quiet = (dir_x <= REVERSAL_TH_POS) && (dir_x >= REVERSAL_TH_NEG)
                   && (dir_y <= REVERSAL_TH_POS) && (dir_y >= REVERSAL_TH_NEG);

    wire locked = (innov_avg < INNOV_LO_Q) && hint_quiet;
    wire [1:0] gain_shift = (ADAPT_GAIN == 0 || !hint_quiet) ? 2'd0 :
                            (innov_avg < INNOV_LO_Q)         ? 2'd2 :
                            (innov_avg < INNOV_HI_Q)         ? 2'd1 : 2'd0;

    // Lock-gated measurement smoothing: /4 EMA of the measurement while
    // locked; reseeded to the raw measurement whenever unlocked so there is
    // never smoothing lag during acquisition or manoeuvres.
    reg signed [QW-1:0] mx_f = {QW{1'b0}};
    reg signed [QW-1:0] my_f = {QW{1'b0}};
    wire signed [QW-1:0] mx_next = mx_f + ((meas_x_q - mx_f) >>> 2);
    wire signed [QW-1:0] my_next = my_f + ((meas_y_q - my_f) >>> 2);
    wire use_filt = (MEAS_FILT != 0) && locked && initialized;
    wire signed [QW-1:0] meas_x_eff = use_filt ? mx_next : meas_x_q;
    wire signed [QW-1:0] meas_y_eff = use_filt ? my_next : meas_y_q;

    // Predicted position (prior to correction)
    wire signed [QW-1:0] x_pred = x_q + vx_q;
    wire signed [QW-1:0] y_pred = y_q + vy_q;

    // Residual (measurement - prediction)
    wire signed [QW-1:0] res_x = meas_x_eff - x_pred;
    wire signed [QW-1:0] res_y = meas_y_eff - y_pred;

    // L1 residual magnitude for the innovation monitor (Q8.8, always >= 0)
    wire [QW-1:0] abs_res_x = res_x[QW-1] ? -res_x : res_x;
    wire [QW-1:0] abs_res_y = res_y[QW-1] ? -res_y : res_y;
    wire [QW-1:0] res_mag   = abs_res_x + abs_res_y;

    // Outlier detection: reject measurements with large residuals
    // Threshold is in Q8.8 format (shift OUTLIER_TH by 8)
    localparam signed [QW-1:0] OUTLIER_TH_Q = OUTLIER_TH << 8;
    localparam signed [QW-1:0] OUTLIER_TH_NEG = -OUTLIER_TH_Q;

    wire outlier_x = (res_x > OUTLIER_TH_Q) || (res_x < OUTLIER_TH_NEG);
    wire outlier_y = (res_y > OUTLIER_TH_Q) || (res_y < OUTLIER_TH_NEG);
    wire is_outlier = outlier_x || outlier_y;

    // Correction terms (scaled by gains, then shift back by 8 for Q8.8)
    // Use wider intermediates to avoid overflow: 24-bit * 9-bit = 33-bit product
    localparam MW = QW + 9;  // Multiplication width to prevent overflow

    wire signed [MW-1:0] pos_corr_x_wide = res_x * A_GAIN;
    wire signed [MW-1:0] pos_corr_y_wide = res_y * A_GAIN;
    wire signed [MW-1:0] vel_corr_x_wide = res_x * B_GAIN;
    wire signed [MW-1:0] vel_corr_y_wide = res_y * B_GAIN;

    // Arithmetic right-shift narrows MW=33 bits to QW=24 bits; upper 9 bits are sign
    // extension of the shifted-out integer portion and are safe to discard.
    // gain_shift (0 when ADAPT_GAIN=0) scales the effective ALPHA down by 2
    // or 4 while locked — innovation-scheduled position gain. Beta is left
    // at full strength: velocity jitter integrates far less into the output
    // than position jitter, and attenuating beta (or the hint) moves the
    // ramp-tracking equilibrium, trading jitter for bias.
    /* verilator lint_off WIDTHTRUNC */
    wire signed [QW-1:0] pos_corr_x = pos_corr_x_wide >>> (8 + gain_shift);
    wire signed [QW-1:0] pos_corr_y = pos_corr_y_wide >>> (8 + gain_shift);
    wire signed [QW-1:0] vel_corr_x = vel_corr_x_wide >>> 8;
    wire signed [QW-1:0] vel_corr_y = vel_corr_y_wide >>> 8;
    /* verilator lint_on  WIDTHTRUNC */

    // Direction hint -> velocity nudge, in Q8.8 px/update.
    // dir_x is the Reichardt correlation magnitude (signed, ~[-128,127]).
    // Extend to Q8.8 (raw value = dir_x px) then scale:  hint_px = dir_x / 2^DIR_HINT_SHIFT.
    // The previous code did (<<<2) then (>>>4) = net /4 in Q8.8 RAW units = dir_x/1024 px,
    // i.e. ~0.12 px even at full magnitude, so the motion detector's magnitude was
    // effectively discarded. DIR_HINT_SHIFT makes the scaling explicit and auditable.
    // Retune in simulation before relying on it (SoC uses a meaningful value).
    wire signed [QW-1:0] dir_x_q = $signed({{(QW-8){dir_x[7]}}, dir_x}) <<< 8;
    wire signed [QW-1:0] dir_y_q = $signed({{(QW-8){dir_y[7]}}, dir_y}) <<< 8;
    wire signed [QW-1:0] dir_vx  = dir_x_q >>> DIR_HINT_SHIFT;
    wire signed [QW-1:0] dir_vy  = dir_y_q >>> DIR_HINT_SHIFT;

    // Corrected position estimate
    wire signed [QW-1:0] x_corrected = x_pred + pos_corr_x;
    wire signed [QW-1:0] y_corrected = y_pred + pos_corr_y;

    // New velocity (before saturation).
    // Uses vx_base / vy_base (not vx_q / vy_q directly) so that on a reversal
    // the accumulated momentum from the old direction is discarded before the
    // residual correction and direction hint are applied.
    wire signed [QW-1:0] vx_new = vx_base + vel_corr_x + dir_vx;
    wire signed [QW-1:0] vy_new = vy_base + vel_corr_y + dir_vy;

    // Velocity saturation function
    function signed [QW-1:0] saturate_vel;
        input signed [QW-1:0] val;
        begin
            if (val > VEL_MAX_Q)
                saturate_vel = VEL_MAX_Q;
            else if (val < VEL_MIN_Q)
                saturate_vel = VEL_MIN_Q;
            else
                saturate_vel = val;
        end
    endfunction

    // Position output clamping: clamp negative to 0, clamp overflow to max
    // Extract integer part from Q8.8 (bits [XW+7:8])
    wire signed [QW-1:0] x_int_signed = x_corrected >>> 8;
    wire signed [QW-1:0] y_int_signed = y_corrected >>> 8;

    // Clamp to valid range [0, 2^XW-1]
    wire [XW-1:0] x_clamped = (x_int_signed < 0) ? {XW{1'b0}} :
                              (x_int_signed >= (1 << XW)) ? {XW{1'b1}} :
                              x_int_signed[XW-1:0];
    wire [YW-1:0] y_clamped = (y_int_signed < 0) ? {YW{1'b0}} :
                              (y_int_signed >= (1 << YW)) ? {YW{1'b1}} :
                              y_int_signed[YW-1:0];

    // Coast position (prediction only, no correction) for outlier handling
    wire signed [QW-1:0] x_int_coast = x_pred >>> 8;
    wire signed [QW-1:0] y_int_coast = y_pred >>> 8;
    wire [XW-1:0] x_coast_clamped = (x_int_coast < 0) ? {XW{1'b0}} :
                                    (x_int_coast >= (1 << XW)) ? {XW{1'b1}} :
                                    x_int_coast[XW-1:0];
    wire [YW-1:0] y_coast_clamped = (y_int_coast < 0) ? {YW{1'b0}} :
                                    (y_int_coast >= (1 << YW)) ? {YW{1'b1}} :
                                    y_int_coast[YW-1:0];

    always @(posedge clk) begin
        if (rst || soft_rst) begin
            out_valid_int <= 1'b0;
            // soft_rst does not clear x_hat/y_hat (hold last output until re-acquired)
            x_q <= {QW{1'b0}};
            y_q <= {QW{1'b0}};
            vx_q <= {QW{1'b0}};
            vy_q <= {QW{1'b0}};
            initialized <= 1'b0;
            // Clear direction history so first post-reset measurement cannot
            // falsely trigger a reversal against stale pre-reset direction state.
            dir_x_prev <= 8'sd0;
            dir_y_prev <= 8'sd0;
            // Innovation monitor restarts at full gain; measurement EMA cleared
            innov_avg <= INNOV_HI_Q;
            mx_f <= {QW{1'b0}};
            my_f <= {QW{1'b0}};
            if (rst) begin
                x_hat <= {PW{1'b0}};
                y_hat <= {PW{1'b0}};
            end
        end else begin
            out_valid_int <= 1'b0;
            if (in_valid) begin
                // Update direction history unconditionally on every measurement
                // event — applies to init, outlier, and normal paths alike.
                // The non-blocking assignment means reversal_x/reversal_y
                // (combinational) still see the OLD dir_x_prev this cycle,
                // which is the correct "previous measurement" direction.
                dir_x_prev <= dir_x;
                dir_y_prev <= dir_y;

                if (!initialized) begin
                    // First measurement: initialize position directly (bypasses outlier check)
                    x_q <= meas_x_q;
                    y_q <= meas_y_q;
                    // Cold-start velocity: if VEL_INIT > 0, pre-load from direction sign.
                    // This cuts warm-up from ~7 updates to ~2 by giving the filter a
                    // reasonable starting velocity estimate.
                    vx_q <= (VEL_INIT > 0) ? ((dir_x > 0) ?  VEL_INIT_Q :
                                               (dir_x < 0) ? -VEL_INIT_Q : {QW{1'b0}})
                                           : {QW{1'b0}};
                    vy_q <= (VEL_INIT > 0) ? ((dir_y > 0) ?  VEL_INIT_Q :
                                               (dir_y < 0) ? -VEL_INIT_Q : {QW{1'b0}})
                                           : {QW{1'b0}};
                    // Output the measurement directly
                    x_hat <= {{(PW-XW){1'b0}}, in_x};
                    y_hat <= {{(PW-YW){1'b0}}, in_y};
                    initialized <= 1'b1;
                    // Acquisition posture: full gain, EMA seeded to measurement
                    innov_avg <= INNOV_HI_Q;
                    mx_f <= meas_x_q;
                    my_f <= meas_y_q;
                end else if (is_outlier) begin
                    // Outlier detected: coast using velocity, don't apply measurement
                    // Position advances by prediction only
                    x_q <= x_pred;
                    y_q <= y_pred;
                    // Decay velocity slightly during outlier (reduce confidence).
                    // Exception: if a direction reversal is also detected, zero
                    // velocity immediately rather than decaying — coasting in the
                    // old direction after a reversal would compound the overshoot
                    // even when no valid measurement is available.
                    vx_q <= reversal_x ? {QW{1'b0}} : saturate_vel(vx_q - (vx_q >>> 4));
                    vy_q <= reversal_y ? {QW{1'b0}} : saturate_vel(vy_q - (vy_q >>> 4));
                    // Output coasted position
                    x_hat <= {{(PW-XW){1'b0}}, x_coast_clamped};
                    y_hat <= {{(PW-YW){1'b0}}, y_coast_clamped};
                end else begin
                    // Normal update: prediction + alpha * residual
                    x_q <= x_corrected;
                    y_q <= y_corrected;
                    // Update velocity with saturation
                    vx_q <= saturate_vel(vx_new);
                    vy_q <= saturate_vel(vy_new);
                    // Output clamped integer position
                    x_hat <= {{(PW-XW){1'b0}}, x_clamped};
                    y_hat <= {{(PW-YW){1'b0}}, y_clamped};
                    // Innovation EMA tracks accepted-measurement residuals only
                    // (outliers must not drive the gain schedule); measurement
                    // EMA commits the value the residual was formed from.
                    innov_avg <= innov_avg - (innov_avg >> 2) + (res_mag >> 2);
                    mx_f <= meas_x_eff;
                    my_f <= meas_y_eff;
                end
                out_valid_int <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
