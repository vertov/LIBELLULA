`timescale 1ns/1ps
`default_nettype none

// tb_prediction_error: Prediction accuracy measurement
// Measures mean and max prediction error in pixels across events
//
// FIXED: The ab_predictor overflow bug has been corrected by using wider
// intermediate registers (33-bit) for Q8.8 multiplication.
// Full coordinate range (0-1023) is now supported.

`include "tb_common_tasks.vh"
module tb_prediction_error;
    localparam T_NS = 5;  // 200 MHz
    localparam XW = 10, YW = 10, AW = 8, DW = 0, PW = 16;
    localparam NUM_EVENTS = 100;  // Events for measurement
    localparam CYCLES_PER_EVENT = 667;  // 300 Hz event rate

    reg clk = 0, rst = 1;
    always #(T_NS/2) clk = ~clk;

    reg aer_req = 0;
    wire aer_ack;
    reg [XW-1:0] aer_x = 100;
    reg [YW-1:0] aer_y = 100;
    reg aer_pol = 0;
    reg [AW-1:0] scan = 0;

    wire pred_valid;
    wire [PW-1:0] x_hat, y_hat;
    wire [7:0] conf;
    wire conf_valid;

    wire [1:0] tid_unused;
    libellula_top #(.XW(XW), .YW(YW), .AW(AW), .DW(DW), .PW(PW)) dut (
        .clk(clk), .rst(rst),
        .aer_req(aer_req), .aer_ack(aer_ack),
        .aer_x(aer_x), .aer_y(aer_y), .aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid), .x_hat(x_hat), .y_hat(y_hat),
        .conf(conf), .conf_valid(conf_valid),
        .track_id(tid_unused)
    );

    // Permissive settings for consistent predictions
    defparam dut.u_lif.LEAK_SHIFT = 0;
    defparam dut.u_lif.THRESH = 1;
    // COUNT_TH removed: v22 burst_gate uses TH_OPEN/TH_CLOSE, not COUNT_TH.

    // Spatial tile hash — must match lif_tile_tmux hashed_xy exactly.
    localparam HX = AW / 2;
    localparam HY = AW - HX;
    function automatic [AW-1:0] hash(input [XW-1:0] x, input [YW-1:0] y);
        hash = {x[XW-1:XW-HX], y[YW-1:YW-HY]};
    endfunction

    // Ground truth position (target moves at constant velocity)
    reg [XW-1:0] true_x = 100;
    reg [YW-1:0] true_y = 100;

    // Error statistics
    integer total_error_x = 0;
    integer total_error_y = 0;
    integer max_error_x = 0;
    integer max_error_y = 0;
    integer max_error_combined = 0;
    integer pred_count = 0;
    integer warmup = 10;  // Ignore first N predictions for filter warmup

    integer i, c, timeout;
    integer err_x, err_y, err_combined;
    integer mean_error_x, mean_error_y, mean_error_combined;

    // Send event and wait for prediction
    task send_event_wait_pred;
        begin
            // Update scan to match current position
            scan = hash(aer_x, aer_y);

            // Pre-hold scan
            repeat (4) @(negedge clk);

            // 4-phase handshake
            aer_req = 1;
            timeout = 50;
            while (aer_ack !== 1 && timeout > 0) begin
                @(negedge clk);
                timeout = timeout - 1;
            end
            @(negedge clk);
            aer_req = 0;
            while (aer_ack !== 0) @(negedge clk);

            // Wait for prediction (up to 64 cycles)
            timeout = 64;
            while (!pred_valid && timeout > 0) begin
                @(negedge clk);
                timeout = timeout - 1;
            end

            // If prediction received, compute error
            if (pred_valid) begin
                // X-corruption guard
                if (^x_hat === 1'bx || ^y_hat === 1'bx) begin
                    $display("FAIL: X/Z-corrupted prediction output at pred %0d", pred_count);
                    fail_msg("X/Z corruption detected on prediction output");
                end

                // Compute absolute error
                err_x = (x_hat > true_x) ? (x_hat - true_x) : (true_x - x_hat);
                err_y = (y_hat > true_y) ? (y_hat - true_y) : (true_y - y_hat);
                err_combined = err_x + err_y;

                // Debug: print first few and periodic predictions
                if (pred_count < 5 || pred_count % 200 == 0) begin
                    $display("  Pred %0d: true=(%0d,%0d) pred=(%0d,%0d) err=(%0d,%0d)",
                             pred_count, true_x, true_y, x_hat, y_hat, err_x, err_y);
                end

                // Skip warmup period
                if (pred_count >= warmup) begin
                    // Accumulate for mean
                    total_error_x = total_error_x + err_x;
                    total_error_y = total_error_y + err_y;

                    // Track max
                    if (err_x > max_error_x) max_error_x = err_x;
                    if (err_y > max_error_y) max_error_y = err_y;
                    if (err_combined > max_error_combined) max_error_combined = err_combined;
                end

                pred_count = pred_count + 1;
            end
        end
    endtask

    initial begin
        #(20*T_NS) rst = 0;

        $display("Prediction Error Test: %0d events with constant velocity motion", NUM_EVENTS);
        $display("Motion: +1 pixel/event in X direction");
        $display("Warmup: %0d predictions ignored", warmup);
        $display("");

        // Initialize position - using larger coordinates to verify overflow fix
        true_x = 100;
        true_y = 200;  // Y=200 previously caused overflow, now fixed
        aer_x = true_x;
        aer_y = true_y;

        // Send events with constant velocity motion (+1 px/event in X)
        for (i = 0; i < NUM_EVENTS; i = i + 1) begin
            // Update true position - full coordinate range now supported
            true_x = 100 + i;  // 100 to 199 for 100 events
            true_y = 200;

            // Set event coordinates to true position
            aer_x = true_x;
            aer_y = true_y;

            // Send event and measure prediction
            send_event_wait_pred();

            // Inter-event delay (300 Hz rate)
            for (c = 0; c < CYCLES_PER_EVENT; c = c + 1) @(negedge clk);

            // Progress indicator
            if (i > 0 && i % 200 == 0) begin
                $display("  Progress: %0d/%0d events", i, NUM_EVENTS);
            end
        end

        // Final drain
        repeat (200) @(negedge clk);

        // Compute statistics
        $display("");
        $display("=== PREDICTION ERROR RESULTS ===");
        $display("Total events sent: %0d", NUM_EVENTS);
        $display("Total predictions received: %0d", pred_count);
        $display("Predictions after warmup: %0d", pred_count - warmup);

        if (pred_count > warmup) begin
            mean_error_x = total_error_x / (pred_count - warmup);
            mean_error_y = total_error_y / (pred_count - warmup);
            mean_error_combined = (total_error_x + total_error_y) / (pred_count - warmup);

            $display("");
            $display("X-axis error:");
            $display("  Mean: %0d pixels", mean_error_x);
            $display("  Max:  %0d pixels", max_error_x);
            $display("");
            $display("Y-axis error:");
            $display("  Mean: %0d pixels", mean_error_y);
            $display("  Max:  %0d pixels", max_error_y);
            $display("");
            $display("Combined (X+Y) error:");
            $display("  Mean: %0d pixels", mean_error_combined);
            $display("  Max:  %0d pixels", max_error_combined);
            $display("");

            // Summary line for easy parsing
            $display("MEAN_ERROR_X=%0d", mean_error_x);
            $display("MEAN_ERROR_Y=%0d", mean_error_y);
            $display("MAX_ERROR_X=%0d", max_error_x);
            $display("MAX_ERROR_Y=%0d", max_error_y);

            // Check against ±2 pixel spec
            if (max_error_x <= 2 && max_error_y <= 2) begin
                $display("");
                $display("RESULT: Within ±2 pixel specification");
                pass();
            end else begin
                $display("");
                $display("RESULT: Exceeds ±2 pixel specification (max_x=%0d max_y=%0d)", max_error_x, max_error_y);
                fail_msg("Prediction error exceeds ±2 pixel specification");
            end
        end else begin
            $display("WARNING: Insufficient predictions for statistics");
            fail_msg("Insufficient predictions received");
        end
    end
endmodule

`default_nettype wire
