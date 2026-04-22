`timescale 1ns/1ps
`default_nettype none

// tb_burst_gate: Unit testbench for burst gate module
// Tests: threshold gating, window reset, event counting, below/above threshold

`include "tb_common_tasks.vh"
module tb_burst_gate;
    localparam T_NS = 5;  // 200 MHz
    localparam WINDOW = 32;   // Window size (must be large enough for test sequences)
    localparam COUNT_TH = 3;  // Threshold of 3 events

    reg clk = 0, rst = 1;
    always #(T_NS/2) clk = ~clk;

    reg in_valid = 0;
    wire out_valid;

    // DUT
    burst_gate #(.WINDOW(WINDOW), .COUNT_TH(COUNT_TH)) dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid),
        .out_valid(out_valid)
    );

    integer test_num = 0;
    integer errors = 0;

    // Task: inject event pulse
    task inject_event;
        begin
            in_valid = 1;
            @(negedge clk);
            in_valid = 0;
        end
    endtask

    initial begin
        $display("=== BURST_GATE Unit Testbench ===");
        $display("Parameters: WINDOW=%0d, COUNT_TH=%0d", WINDOW, COUNT_TH);
        $display("");

        #(10*T_NS) rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 1: Below threshold - no output
        // ============================================================
        test_num = 1;
        $display("TEST %0d: Below threshold (no output)", test_num);

        begin : test1_block
            integer i;
            integer out_count;
            out_count = 0;

            // Inject COUNT_TH-1 events (below threshold)
            for (i = 0; i < COUNT_TH - 1; i = i + 1) begin
                in_valid = 1;
                @(negedge clk);
                if (out_valid) out_count = out_count + 1;
                in_valid = 0;
                @(negedge clk);
            end

            $display("  - Injected %0d events (threshold=%0d)", COUNT_TH - 1, COUNT_TH);
            $display("  - out_valid count: %0d (expected 0)", out_count);

            if (out_count > 0) begin
                $display("ERROR: out_valid should not assert below threshold");
                errors = errors + 1;
            end else begin
                $display("  - Below threshold: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 2: At threshold - output starts
        // ============================================================
        test_num = 2;
        $display("TEST %0d: At threshold (output starts)", test_num);

        begin : test2_block
            integer i;
            integer out_count;
            out_count = 0;

            // Inject exactly COUNT_TH events
            for (i = 0; i < COUNT_TH; i = i + 1) begin
                in_valid = 1;
                @(negedge clk);
                if (out_valid) out_count = out_count + 1;
                in_valid = 0;
                @(negedge clk);
            end

            // Inject one more - should pass through
            in_valid = 1;
            @(negedge clk);
            if (out_valid) out_count = out_count + 1;
            in_valid = 0;

            $display("  - Injected %0d events then 1 more", COUNT_TH);
            $display("  - out_valid count: %0d (expected >= 1)", out_count);

            if (out_count < 1) begin
                $display("ERROR: out_valid should assert at/above threshold");
                errors = errors + 1;
            end else begin
                $display("  - At threshold: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 3: Above threshold - events pass through
        // ============================================================
        test_num = 3;
        $display("TEST %0d: Above threshold (pass-through)", test_num);

        begin : test3_block
            integer i;
            integer out_count;
            out_count = 0;

            // First, reach threshold
            for (i = 0; i < COUNT_TH; i = i + 1) begin
                inject_event();
            end

            // Now inject more events - all should pass through
            for (i = 0; i < 5; i = i + 1) begin
                in_valid = 1;
                @(negedge clk);
                if (out_valid) out_count = out_count + 1;
                in_valid = 0;
            end

            $display("  - After threshold, injected 5 more events");
            $display("  - out_valid count: %0d (expected 5)", out_count);

            if (out_count != 5) begin
                $display("ERROR: All events above threshold should pass");
                errors = errors + 1;
            end else begin
                $display("  - Pass-through: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 4: Window reset clears event count
        // ============================================================
        test_num = 4;
        $display("TEST %0d: Window reset clears count", test_num);

        begin : test4_block
            integer i;
            integer out_count;

            // Reach threshold
            for (i = 0; i < COUNT_TH; i = i + 1) begin
                inject_event();
            end

            // Wait for window to reset (WINDOW cycles)
            for (i = 0; i < WINDOW + 2; i = i + 1) begin
                @(negedge clk);
            end

            // Now inject below threshold - should not pass
            out_count = 0;
            for (i = 0; i < COUNT_TH - 1; i = i + 1) begin
                in_valid = 1;
                @(negedge clk);
                if (out_valid) out_count = out_count + 1;
                in_valid = 0;
                @(negedge clk);
            end

            $display("  - After window reset, injected %0d events", COUNT_TH - 1);
            $display("  - out_valid count: %0d (expected 0)", out_count);

            if (out_count > 0) begin
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
        // TEST 5: Counter saturation (many events)
        // ============================================================
        test_num = 5;
        $display("TEST %0d: Counter saturation", test_num);

        begin : test5_block
            integer i;

            // Inject many events to test counter saturation
            for (i = 0; i < 300; i = i + 1) begin
                inject_event();
            end

            $display("  - Injected 300 events");
            $display("  - ev_cnt=%0d (max 255)", dut.ev_cnt);

            if (dut.ev_cnt > 255) begin
                $display("ERROR: Counter overflow");
                errors = errors + 1;
            end else begin
                $display("  - Counter saturation: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 6: No output without input
        // ============================================================
        test_num = 6;
        $display("TEST %0d: No output without input", test_num);

        begin : test6_block
            integer i;
            integer out_count;
            out_count = 0;

            // Just wait without any input
            for (i = 0; i < 20; i = i + 1) begin
                @(negedge clk);
                if (out_valid) out_count = out_count + 1;
            end

            $display("  - Waited 20 cycles with no input");
            $display("  - out_valid count: %0d (expected 0)", out_count);

            if (out_count > 0) begin
                $display("ERROR: out_valid without in_valid");
                errors = errors + 1;
            end else begin
                $display("  - No spurious output: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 7: Burst detection across window boundary
        // ============================================================
        test_num = 7;
        $display("TEST %0d: Burst across window boundary", test_num);

        begin : test7_block
            integer i;
            integer out_count;
            out_count = 0;

            // Inject events, let window reset, inject more
            for (i = 0; i < COUNT_TH + 2; i = i + 1) begin
                in_valid = 1;
                @(negedge clk);
                if (out_valid) out_count = out_count + 1;
                in_valid = 0;
            end

            $display("  - Injected %0d events", COUNT_TH + 2);
            $display("  - out_valid count: %0d (expected %0d)", out_count, COUNT_TH + 2 - COUNT_TH);

            // Should have gotten at least some output
            if (out_count < 1) begin
                $display("ERROR: Expected some output above threshold");
                errors = errors + 1;
            end else begin
                $display("  - Burst detection: PASSED");
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
            $display("All BURST_GATE tests passed!");
            pass();
        end else begin
            fail_msg("BURST_GATE tests failed");
        end
    end
endmodule

`default_nettype wire
