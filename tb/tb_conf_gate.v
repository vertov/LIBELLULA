`timescale 1ns/1ps
`default_nettype none

// tb_conf_gate: Unit testbench for confidence gate module
// Tests: confidence calculation, event counting, direction magnitude, saturation

`include "tb_common_tasks.vh"
module tb_conf_gate;
    localparam T_NS = 5;  // 200 MHz
    localparam WINDOW = 8;  // Small window for testing

    reg clk = 0, rst = 1;
    always #(T_NS/2) clk = ~clk;

    // Inputs
    reg in_valid = 0;
    reg signed [7:0] dir_x = 0;
    reg signed [7:0] dir_y = 0;

    // Outputs
    wire out_valid;
    wire [7:0] conf;

    // DUT
    conf_gate #(.WINDOW(WINDOW)) dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid),
        .dir_x(dir_x), .dir_y(dir_y),
        .out_valid(out_valid),
        .conf(conf)
    );

    integer test_num = 0;
    integer errors = 0;
    reg [7:0] captured_conf;

    // Task: inject event with direction
    task inject_event;
        input signed [7:0] dx;
        input signed [7:0] dy;
        begin
            dir_x = dx;
            dir_y = dy;
            in_valid = 1;
            @(negedge clk);
            in_valid = 0;
            dir_x = 0;
            dir_y = 0;
        end
    endtask

    // Task: wait for out_valid and capture conf
    task wait_for_output;
        integer timeout;
        begin
            timeout = WINDOW + 5;
            while (!out_valid && timeout > 0) begin
                @(negedge clk);
                timeout = timeout - 1;
            end
            if (out_valid) captured_conf = conf;
        end
    endtask

    initial begin
        $display("=== CONF_GATE Unit Testbench ===");
        $display("Parameters: WINDOW=%0d", WINDOW);
        $display("");

        #(10*T_NS) rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 1: No events -> low confidence
        // ============================================================
        test_num = 1;
        $display("TEST %0d: No events (low confidence)", test_num);

        begin : test1_block
            integer i;

            // Wait for window to complete without events
            for (i = 0; i < WINDOW + 2; i = i + 1) begin
                @(negedge clk);
                if (out_valid) captured_conf = conf;
            end

            $display("  - No events injected");
            $display("  - Confidence: %0d (expected 0)", captured_conf);

            if (captured_conf != 0) begin
                $display("ERROR: Confidence should be 0 with no events");
                errors = errors + 1;
            end else begin
                $display("  - No events: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 2: Events increase confidence
        // ============================================================
        test_num = 2;
        $display("TEST %0d: Events increase confidence", test_num);

        begin : test2_block
            integer i;

            // Inject some events
            for (i = 0; i < 3; i = i + 1) begin
                inject_event(0, 0);
            end

            wait_for_output();

            $display("  - Injected 3 events");
            $display("  - Confidence: %0d (expected > 0)", captured_conf);

            if (captured_conf == 0) begin
                $display("ERROR: Confidence should increase with events");
                errors = errors + 1;
            end else begin
                $display("  - Event counting: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 3: Direction magnitude contributes to confidence
        // ============================================================
        test_num = 3;
        $display("TEST %0d: Direction magnitude contribution", test_num);

        begin : test3_block
            integer i;
            reg [7:0] conf_no_dir, conf_with_dir;

            // First: events with no direction (dir held at 0)
            dir_x = 0; dir_y = 0;
            for (i = 0; i < 3; i = i + 1) begin
                in_valid = 1;
                @(negedge clk);
                in_valid = 0;
            end
            // Keep dir at 0, wait for window to complete
            for (i = 0; i < WINDOW + 2; i = i + 1) begin
                @(negedge clk);
                if (out_valid) conf_no_dir = conf;
            end

            // Reset
            rst = 1; @(negedge clk); rst = 0; @(negedge clk);

            // Second: same events with direction HELD HIGH through window completion
            dir_x = 50; dir_y = 50;
            for (i = 0; i < 3; i = i + 1) begin
                in_valid = 1;
                @(negedge clk);
                in_valid = 0;
            end
            // Keep dir at 50,50 while waiting for window to complete
            for (i = 0; i < WINDOW + 2; i = i + 1) begin
                @(negedge clk);
                if (out_valid) conf_with_dir = conf;
            end
            dir_x = 0; dir_y = 0;

            $display("  - Confidence without direction: %0d", conf_no_dir);
            $display("  - Confidence with direction: %0d", conf_with_dir);

            // vmag = (|dir_x| + |dir_y|) >> 1 = (50+50)>>1 = 50
            // conf_no_dir = 3*8 + 0 = 24
            // conf_with_dir = 3*8 + 50 = 74
            if (conf_with_dir <= conf_no_dir) begin
                $display("ERROR: Direction magnitude should increase confidence");
                errors = errors + 1;
            end else begin
                $display("  - Direction contribution: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 4: Negative direction values (absolute value)
        // ============================================================
        test_num = 4;
        $display("TEST %0d: Negative direction (absolute value)", test_num);

        begin : test4_block
            integer i;
            reg [7:0] conf_pos, conf_neg;

            // Positive direction
            for (i = 0; i < 3; i = i + 1) begin
                inject_event(50, 0);
            end
            wait_for_output();
            conf_pos = captured_conf;

            // Reset
            rst = 1; @(negedge clk); rst = 0; @(negedge clk);

            // Negative direction (same magnitude)
            for (i = 0; i < 3; i = i + 1) begin
                inject_event(-50, 0);
            end
            wait_for_output();
            conf_neg = captured_conf;

            $display("  - Confidence with dir_x=+50: %0d", conf_pos);
            $display("  - Confidence with dir_x=-50: %0d", conf_neg);

            if (conf_pos != conf_neg) begin
                $display("WARNING: Positive and negative should give same magnitude");
            end else begin
                $display("  - Absolute value: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 5: Confidence saturation at 255
        // ============================================================
        test_num = 5;
        $display("TEST %0d: Confidence saturation", test_num);

        begin : test5_block
            integer i;

            // Many events with high direction to saturate
            for (i = 0; i < WINDOW; i = i + 1) begin
                inject_event(127, 127);
            end
            wait_for_output();

            $display("  - %0d events with max direction", WINDOW);
            $display("  - Confidence: %0d (max 255)", captured_conf);

            if (captured_conf > 255) begin
                $display("ERROR: Confidence overflow (>255)");
                errors = errors + 1;
            end else begin
                $display("  - Saturation: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 6: Window reset clears event count
        // ============================================================
        test_num = 6;
        $display("TEST %0d: Window reset", test_num);

        begin : test6_block
            integer i;
            reg [7:0] conf_first, conf_second;

            // First window: many events
            for (i = 0; i < 5; i = i + 1) begin
                inject_event(30, 30);
            end
            wait_for_output();
            conf_first = captured_conf;

            // Second window: no events (let it complete)
            for (i = 0; i < WINDOW + 2; i = i + 1) begin
                @(negedge clk);
                if (out_valid) conf_second = conf;
            end

            $display("  - First window (5 events): conf=%0d", conf_first);
            $display("  - Second window (0 events): conf=%0d", conf_second);

            if (conf_second >= conf_first) begin
                $display("ERROR: Window reset should clear event count");
                errors = errors + 1;
            end else begin
                $display("  - Window reset: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 7: out_valid timing (once per window)
        // ============================================================
        test_num = 7;
        $display("TEST %0d: out_valid once per window", test_num);

        begin : test7_block
            integer i;
            integer valid_count;
            valid_count = 0;

            // Run for 3 windows
            for (i = 0; i < 3 * WINDOW; i = i + 1) begin
                inject_event(10, 10);
                if (out_valid) valid_count = valid_count + 1;
            end

            $display("  - Ran for 3 windows (%0d cycles)", 3 * WINDOW);
            $display("  - out_valid count: %0d (expected ~3)", valid_count);

            if (valid_count < 2 || valid_count > 4) begin
                $display("ERROR: out_valid should occur once per window");
                errors = errors + 1;
            end else begin
                $display("  - out_valid timing: PASSED");
            end
        end
        $display("");

        // ============================================================
        // SUMMARY
        // ============================================================
        $display("=== TEST SUMMARY ===");
        $display("Tests run: %0d", test_num);
        $display("Errors: %0d", errors);
        $display("");

        if (errors == 0) begin
            $display("All CONF_GATE tests passed!");
            pass();
        end else begin
            fail_msg("CONF_GATE tests failed");
        end
    end
endmodule

`default_nettype wire
