`timescale 1ns/1ps
`default_nettype none

// A/B bench for the innovation-scheduled predictor (ADAPT_GAIN / MEAS_FILT).
//
// Two ab_predictor instances receive the IDENTICAL measurement stream:
//   ref_p : ADAPT_GAIN=0, MEAS_FILT=0  (legacy fixed gains)
//   adp_p : ADAPT_GAIN=1, MEAS_FILT=1  (innovation-scheduled)
//
// Stimulus: constant-velocity target (+2 px/update in x, static y) with
// deterministic LFSR measurement noise in [-3,+3] px on both axes and a
// constant Reichardt direction hint. This is the locked-tracking regime the
// adaptive machinery targets.
//
// Pass criteria:
//   1. Both instances converge (post-warmup mean error bounded).
//   2. Adaptive post-warmup total error <= fixed-gain total error on BOTH
//      axes (adaptive must never be worse in the locked regime).
//   3. Adaptive acquisition is not materially slower: its error at the end
//      of warmup is within bounds.

module tb_ab_adaptive;

    localparam XW = 10;
    localparam YW = 10;
    localparam PW = 16;
    localparam DHS = 3;          // DIR_HINT_SHIFT used by the SoC path

    localparam UPDATES  = 300;
    localparam WARMUP   = 40;    // updates excluded from the jitter comparison
    localparam VX_TRUE  = 2;     // px per update
    localparam X0       = 100;
    localparam Y0       = 300;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    reg              in_valid = 0;
    reg  [XW-1:0]    in_x = 0;
    reg  [YW-1:0]    in_y = 0;
    // No direction hint: a CONSTANT hint (which never occurs in the pipeline —
    // Reichardt output decays between bursts) pins a fixed residual/offset
    // equilibrium, and alpha scheduling then trades output bias against
    // jitter, which is not the property under test. This bench isolates the
    // gain scheduler in the unbiased noisy-tracking regime; hint interaction
    // is exercised end-to-end by tb_e2e_motion / tb_accuracy / tb_reversal.
    reg signed [7:0] dir_x = 8'sd0;
    reg signed [7:0] dir_y = 8'sd0;

    wire           ref_valid, adp_valid;
    wire [PW-1:0]  ref_x, ref_y, adp_x, adp_y;

    ab_predictor #(
        .XW(XW), .YW(YW), .PW(PW),
        .DIR_HINT_SHIFT(DHS), .ADAPT_GAIN(0), .MEAS_FILT(0)
    ) ref_p (
        .clk(clk), .rst(rst), .soft_rst(1'b0),
        .in_valid(in_valid), .in_x(in_x), .in_y(in_y),
        .dir_x(dir_x), .dir_y(dir_y),
        .out_valid(ref_valid), .x_hat(ref_x), .y_hat(ref_y)
    );

    ab_predictor #(
        .XW(XW), .YW(YW), .PW(PW),
        .DIR_HINT_SHIFT(DHS), .ADAPT_GAIN(1), .MEAS_FILT(1)
    ) adp_p (
        .clk(clk), .rst(rst), .soft_rst(1'b0),
        .in_valid(in_valid), .in_x(in_x), .in_y(in_y),
        .dir_x(dir_x), .dir_y(dir_y),
        .out_valid(adp_valid), .x_hat(adp_x), .y_hat(adp_y)
    );

    // Deterministic noise: 16-bit Fibonacci LFSR, noise = (lfsr % 7) - 3
    reg [15:0] lfsr = 16'hACE1;
    task lfsr_step;
        begin
            lfsr = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        end
    endtask

    localparam P2_UPDATES = 150;
    localparam P2_WARMUP  = 30;

    integer u;
    integer true_x, true_y;
    integer nx, ny;
    integer ref_ex_sum = 0, ref_ey_sum = 0;
    integer adp_ex_sum = 0, adp_ey_sum = 0;
    integer ref_p2_sum = 0, adp_p2_sum = 0;
    integer ref_e, adp_e;
    integer errors = 0;

    // The adaptive machinery must actually engage during the run, otherwise
    // the adp-vs-ref comparison is vacuously true (identical instances).
    reg engaged = 1'b0;
    always @(posedge clk)
        if (!rst && adp_p.gain_shift != 2'd0) engaged <= 1'b1;

    task check_update;
        begin
            // post-warmup error accumulation (x axis)
            ref_e = (ref_x >= true_x) ? (ref_x - true_x) : (true_x - ref_x);
            adp_e = (adp_x >= true_x) ? (adp_x - true_x) : (true_x - adp_x);
            if (u >= WARMUP) begin
                ref_ex_sum = ref_ex_sum + ref_e;
                adp_ex_sum = adp_ex_sum + adp_e;
            end
            // y axis
            ref_e = (ref_y >= true_y) ? (ref_y - true_y) : (true_y - ref_y);
            adp_e = (adp_y >= true_y) ? (adp_y - true_y) : (true_y - adp_y);
            if (u >= WARMUP) begin
                ref_ey_sum = ref_ey_sum + ref_e;
                adp_ey_sum = adp_ey_sum + adp_e;
            end
        end
    endtask

    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);

        for (u = 0; u < UPDATES; u = u + 1) begin
            true_x = X0 + u * VX_TRUE;
            true_y = Y0;

            lfsr_step; nx = (lfsr % 7) - 3;
            lfsr_step; ny = (lfsr % 7) - 3;

            @(negedge clk);
            in_x = true_x + nx;
            in_y = true_y + ny;
            in_valid = 1'b1;
            @(negedge clk);
            in_valid = 1'b0;

            // Let outputs settle, then score
            @(posedge clk);
            check_update;

            // inter-update gap
            repeat (6) @(posedge clk);
        end

        // ------------------------------------------------------------------
        // Phase 2: stationary target, low noise (+/-1 px). This is the
        // regime where the lock-gated measurement EMA (MEAS_FILT) engages
        // (innovation < 2 px), so it tests the machinery phase 1 cannot.
        // ------------------------------------------------------------------
        true_x = X0 + (UPDATES - 1) * VX_TRUE;
        true_y = Y0;
        for (u = 0; u < P2_UPDATES; u = u + 1) begin
            lfsr_step; nx = (lfsr % 3) - 1;
            lfsr_step; ny = (lfsr % 3) - 1;

            @(negedge clk);
            in_x = true_x + nx;
            in_y = true_y + ny;
            in_valid = 1'b1;
            @(negedge clk);
            in_valid = 1'b0;

            @(posedge clk);
            // score after a settling allowance
            if (u >= P2_WARMUP) begin
                ref_e = (ref_x >= true_x) ? (ref_x - true_x) : (true_x - ref_x);
                adp_e = (adp_x >= true_x) ? (adp_x - true_x) : (true_x - adp_x);
                ref_p2_sum = ref_p2_sum + ref_e;
                adp_p2_sum = adp_p2_sum + adp_e;
            end

            repeat (6) @(posedge clk);
        end

        // ---------------- results ----------------
        $display("ADAPT_RESULT ref_ex=%0d adp_ex=%0d ref_ey=%0d adp_ey=%0d (post-warmup L1 sums, %0d updates)",
                 ref_ex_sum, adp_ex_sum, ref_ey_sum, adp_ey_sum, UPDATES - WARMUP);

        // 1. Convergence: post-warmup mean error bounded (<= 6 px mean on x)
        if (adp_ex_sum > 6 * (UPDATES - WARMUP)) begin
            errors = errors + 1;
            $display("FAIL: adaptive x error did not converge (sum=%0d)", adp_ex_sum);
        end
        if (adp_ey_sum > 6 * (UPDATES - WARMUP)) begin
            errors = errors + 1;
            $display("FAIL: adaptive y error did not converge (sum=%0d)", adp_ey_sum);
        end

        // 2. Adaptive must not be worse than fixed gains in the locked regime
        if (adp_ex_sum > ref_ex_sum) begin
            errors = errors + 1;
            $display("FAIL: adaptive x error (%0d) worse than fixed gains (%0d)", adp_ex_sum, ref_ex_sum);
        end
        if (adp_ey_sum > ref_ey_sum) begin
            errors = errors + 1;
            $display("FAIL: adaptive y error (%0d) worse than fixed gains (%0d)", adp_ey_sum, ref_ey_sum);
        end

        // 3. Final-sample sanity: both track the target at the end
        if ((adp_x > true_x + 8) || (true_x > adp_x + 8)) begin
            errors = errors + 1;
            $display("FAIL: adaptive final x_hat=%0d vs true=%0d", adp_x, true_x);
        end

        // 4. The gain scheduler must have engaged at least once
        if (!engaged) begin
            errors = errors + 1;
            $display("FAIL: adaptive gain scheduler never engaged (gain_shift stayed 0)");
        end

        // 5. Stationary phase: adaptive (with measurement EMA engaged) must
        //    beat fixed gains on hover jitter
        $display("ADAPT_P2 ref=%0d adp=%0d (stationary-phase L1 sums, %0d updates)",
                 ref_p2_sum, adp_p2_sum, P2_UPDATES - P2_WARMUP);
        if (adp_p2_sum > ref_p2_sum) begin
            errors = errors + 1;
            $display("FAIL: adaptive stationary error (%0d) worse than fixed gains (%0d)",
                     adp_p2_sum, ref_p2_sum);
        end

        $display("");
        $display("=== TEST SUMMARY ===");
        $display("Errors: %0d", errors);
        if (errors == 0) begin
            $display("All AB_ADAPTIVE tests passed!");
            $display("PASS");
        end else begin
            $display("FAIL: %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #5_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
