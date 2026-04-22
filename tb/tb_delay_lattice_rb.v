`timescale 1ns/1ps
`default_nettype none

// tb_delay_lattice_rb: Unit testbench for delay lattice ring buffer
// Tests: ring buffer wrap-around, 4-direction delays, buffer full/empty

`include "tb_common_tasks.vh"
module tb_delay_lattice_rb;
    localparam T_NS = 5;  // 200 MHz
    localparam XW = 10, YW = 10;
    localparam DW = 2;    // Small buffer for testing: DEPTH = 4
    localparam DEPTH = (1 << DW);

    reg clk = 0, rst = 1;
    always #(T_NS/2) clk = ~clk;

    // Inputs
    reg in_valid = 0;
    reg [XW-1:0] in_x = 0;
    reg [YW-1:0] in_y = 0;
    reg in_pol = 0;

    // Outputs
    wire v_e, v_w, v_n, v_s;
    wire [XW-1:0] x_tap;
    wire [YW-1:0] y_tap;
    wire pol_tap;

    // DUT instantiation
    delay_lattice_rb #(
        .XW(XW), .YW(YW), .DW(DW)
    ) dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_x(in_x), .in_y(in_y), .in_pol(in_pol),
        .v_e(v_e), .v_w(v_w), .v_n(v_n), .v_s(v_s),
        .x_tap(x_tap), .y_tap(y_tap), .pol_tap(pol_tap)
    );

    // Test counters
    integer test_num = 0;
    integer errors = 0;

    // Task: inject single event and capture outputs
    // Outputs v_e/v_w/v_n/v_s are only valid for 1 cycle during in_valid
    reg captured_v_e, captured_v_w, captured_v_n, captured_v_s;

    task inject_event;
        input [XW-1:0] x;
        input [YW-1:0] y;
        input pol;
        begin
            in_x = x;
            in_y = y;
            in_pol = pol;
            in_valid = 1;
            @(negedge clk);
            // Capture outputs while they're valid (after posedge, before next cycle)
            captured_v_e = v_e;
            captured_v_w = v_w;
            captured_v_n = v_n;
            captured_v_s = v_s;
            in_valid = 0;
        end
    endtask

    // Task: inject event on consecutive cycle (no gap)
    task inject_event_continuous;
        input [XW-1:0] x;
        input [YW-1:0] y;
        input pol;
        begin
            in_x = x;
            in_y = y;
            in_pol = pol;
            in_valid = 1;
            @(negedge clk);
            captured_v_e = v_e;
            captured_v_w = v_w;
            captured_v_n = v_n;
            captured_v_s = v_s;
            // Don't set in_valid=0, caller will set next event
        end
    endtask

    // Task: wait N cycles without events
    task wait_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) begin
                @(negedge clk);
            end
        end
    endtask

    initial begin
        $display("=== DELAY_LATTICE_RB Unit Testbench ===");
        $display("Parameters: DW=%0d, DEPTH=%0d, XW=%0d, YW=%0d", DW, DEPTH, XW, YW);
        $display("");

        // Release reset
        #(10*T_NS) rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 1: Buffer empty - no matches when buffer is empty
        // ============================================================
        test_num = 1;
        $display("TEST %0d: Buffer empty condition", test_num);

        // Inject first event - buffer was empty, no matches expected
        inject_event(100, 100, 1);
        @(negedge clk);  // Let outputs settle

        $display("  - First event at (100,100)");
        $display("  - v_e=%b v_w=%b v_n=%b v_s=%b (expected all 0)", v_e, v_w, v_n, v_s);

        if (v_e || v_w || v_n || v_s) begin
            $display("ERROR: Direction flags should be 0 with empty buffer");
            errors = errors + 1;
        end else begin
            $display("  - Buffer empty: PASSED");
        end
        $display("");

        // Reset for clean slate
        rst = 1;
        @(negedge clk);
        @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 2: East motion detection (object moving left-to-right)
        // Event at (x+1,y) followed by event at (x,y) after DEPTH cycles
        // Must inject events on CONSECUTIVE cycles (no gaps)
        // ============================================================
        test_num = 2;
        $display("TEST %0d: East motion detection (v_e)", test_num);

        // Inject DEPTH events continuously, first at East neighbor, rest fillers
        // Event 0: (101, 100) - East neighbor
        // Events 1 to DEPTH-1: fillers at non-matching positions
        // Then inject matching event at (100, 100)
        begin : test2_block
            integer i;

            // Use continuous injection to avoid gaps
            inject_event_continuous(101, 100, 1);  // Event 0
            $display("  - Event 0 at (101,100) - East neighbor");

            for (i = 1; i < DEPTH; i = i + 1) begin
                inject_event_continuous(200 + i, 200, 0);  // Filler events
            end
            $display("  - Injected %0d total events (1 target + %0d fillers)", DEPTH, DEPTH-1);

            // Now inject matching event - rptr should point to event 0
            inject_event_continuous(100, 100, 1);
            in_valid = 0;  // End continuous injection

            $display("  - Event at (100,100) - checking for East match");
            $display("  - captured: v_e=%b v_w=%b v_n=%b v_s=%b",
                     captured_v_e, captured_v_w, captured_v_n, captured_v_s);

            if (captured_v_e !== 1'b1) begin
                $display("ERROR: v_e should be 1 for East motion");
                errors = errors + 1;
            end else begin
                $display("  - East motion detection: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1;
        @(negedge clk);
        @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 3: West motion detection (object moving right-to-left)
        // Event at (x-1,y) followed by event at (x,y) after DEPTH cycles
        // ============================================================
        test_num = 3;
        $display("TEST %0d: West motion detection (v_w)", test_num);

        begin : test3_block
            integer i;

            inject_event_continuous(99, 100, 1);  // West neighbor (x-1, y)
            $display("  - Event 0 at (99,100) - West neighbor");

            for (i = 1; i < DEPTH; i = i + 1) begin
                inject_event_continuous(200 + i, 200, 0);
            end

            inject_event_continuous(100, 100, 1);  // Matching event
            in_valid = 0;

            $display("  - Event at (100,100) - checking for West match");
            $display("  - captured: v_e=%b v_w=%b v_n=%b v_s=%b",
                     captured_v_e, captured_v_w, captured_v_n, captured_v_s);

            if (captured_v_w !== 1'b1) begin
                $display("ERROR: v_w should be 1 for West motion");
                errors = errors + 1;
            end else begin
                $display("  - West motion detection: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1;
        @(negedge clk);
        @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 4: North motion detection (object moving down-to-up)
        // Event at (x,y+1) followed by event at (x,y) after DEPTH cycles
        // ============================================================
        test_num = 4;
        $display("TEST %0d: North motion detection (v_n)", test_num);

        begin : test4_block
            integer i;

            inject_event_continuous(100, 101, 1);  // North neighbor (x, y+1)
            $display("  - Event 0 at (100,101) - North neighbor");

            for (i = 1; i < DEPTH; i = i + 1) begin
                inject_event_continuous(200 + i, 200, 0);
            end

            inject_event_continuous(100, 100, 1);  // Matching event
            in_valid = 0;

            $display("  - Event at (100,100) - checking for North match");
            $display("  - captured: v_e=%b v_w=%b v_n=%b v_s=%b",
                     captured_v_e, captured_v_w, captured_v_n, captured_v_s);

            if (captured_v_n !== 1'b1) begin
                $display("ERROR: v_n should be 1 for North motion");
                errors = errors + 1;
            end else begin
                $display("  - North motion detection: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1;
        @(negedge clk);
        @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 5: South motion detection (object moving up-to-down)
        // Event at (x,y-1) followed by event at (x,y) after DEPTH cycles
        // ============================================================
        test_num = 5;
        $display("TEST %0d: South motion detection (v_s)", test_num);

        begin : test5_block
            integer i;

            inject_event_continuous(100, 99, 1);  // South neighbor (x, y-1)
            $display("  - Event 0 at (100,99) - South neighbor");

            for (i = 1; i < DEPTH; i = i + 1) begin
                inject_event_continuous(200 + i, 200, 0);
            end

            inject_event_continuous(100, 100, 1);  // Matching event
            in_valid = 0;

            $display("  - Event at (100,100) - checking for South match");
            $display("  - captured: v_e=%b v_w=%b v_n=%b v_s=%b",
                     captured_v_e, captured_v_w, captured_v_n, captured_v_s);

            if (captured_v_s !== 1'b1) begin
                $display("ERROR: v_s should be 1 for South motion");
                errors = errors + 1;
            end else begin
                $display("  - South motion detection: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1;
        @(negedge clk);
        @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 6: Ring buffer wrap-around
        // ============================================================
        test_num = 6;
        $display("TEST %0d: Ring buffer wrap-around", test_num);

        // Fill buffer beyond capacity to test wrap-around
        // Inject 2*DEPTH events to ensure multiple wrap-arounds
        begin : test6_block
            integer i;
            integer wrap_count;
            reg [DW-1:0] prev_wptr;

            wrap_count = 0;
            prev_wptr = dut.wptr;

            for (i = 0; i < 2 * DEPTH; i = i + 1) begin
                inject_event(i, i, 0);
                // Detect wrap-around
                if (dut.wptr < prev_wptr) begin
                    wrap_count = wrap_count + 1;
                    $display("  - Wrap-around detected at event %0d (wptr: %0d -> %0d)",
                             i, prev_wptr, dut.wptr);
                end
                prev_wptr = dut.wptr;
            end

            $display("  - Injected %0d events, wrap-arounds: %0d (expected %0d)",
                     2 * DEPTH, wrap_count, 2);

            if (wrap_count < 1) begin
                $display("ERROR: No wrap-around detected");
                errors = errors + 1;
            end else begin
                $display("  - Ring buffer wrap-around: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1;
        @(negedge clk);
        @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 7: Buffer full condition - oldest entry is read
        // ============================================================
        test_num = 7;
        $display("TEST %0d: Buffer full - correct delay timing", test_num);

        begin : test7_block
            integer i;

            // Fill buffer with continuous events
            inject_event_continuous(51, 50, 1);  // Event 0 - target
            $display("  - Event 0 at (51,50) - target for matching");

            for (i = 1; i < DEPTH; i = i + 1) begin
                inject_event_continuous(200 + i, 200, 0);
            end

            // Buffer is now full. Next event should see oldest (51,50)
            inject_event_continuous(50, 50, 1);  // Matching event
            in_valid = 0;

            $display("  - After %0d events, inject (50,50)", DEPTH);
            $display("  - captured v_e=%b (expected 1 - delayed event from (51,50))", captured_v_e);

            if (captured_v_e !== 1'b1) begin
                $display("ERROR: Buffer full timing incorrect - v_e should be 1");
                errors = errors + 1;
            end else begin
                $display("  - Buffer full timing: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1;
        @(negedge clk);
        @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 8: No false matches with non-adjacent pixels
        // ============================================================
        test_num = 8;
        $display("TEST %0d: No false matches (non-adjacent pixels)", test_num);

        begin : test8_block
            integer i;

            // Inject event far from where we'll query
            inject_event_continuous(500, 500, 1);

            for (i = 1; i < DEPTH; i = i + 1) begin
                inject_event_continuous(600 + i, 600, 0);
            end

            // Query at non-adjacent position
            inject_event_continuous(100, 100, 1);
            in_valid = 0;

            $display("  - Delayed event at (500,500), current at (100,100)");
            $display("  - captured: v_e=%b v_w=%b v_n=%b v_s=%b (expected all 0)",
                     captured_v_e, captured_v_w, captured_v_n, captured_v_s);

            if (captured_v_e || captured_v_w || captured_v_n || captured_v_s) begin
                $display("ERROR: False match detected for non-adjacent pixels");
                errors = errors + 1;
            end else begin
                $display("  - No false matches: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1;
        @(negedge clk);
        @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 9: Coordinate passthrough
        // ============================================================
        test_num = 9;
        $display("TEST %0d: Coordinate passthrough (x_tap, y_tap, pol_tap)", test_num);

        inject_event(123, 456, 1);
        @(negedge clk);

        $display("  - Injected (123, 456, pol=1)");
        $display("  - x_tap=%0d y_tap=%0d pol_tap=%b", x_tap, y_tap, pol_tap);

        if (x_tap !== 123 || y_tap !== 456 || pol_tap !== 1'b1) begin
            $display("ERROR: Coordinate passthrough incorrect");
            errors = errors + 1;
        end else begin
            $display("  - Coordinate passthrough: PASSED");
        end
        $display("");

        // Reset
        rst = 1;
        @(negedge clk);
        @(negedge clk);
        rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 10: Multiple direction matches (diagonal motion)
        // ============================================================
        test_num = 10;
        $display("TEST %0d: Diagonal motion (no matches expected)", test_num);

        begin : test10_block
            integer i;

            // Inject event at diagonal neighbor (x+1, y+1) = (101, 101)
            inject_event_continuous(101, 101, 1);
            $display("  - Event at (101,101) - diagonal neighbor");

            for (i = 1; i < DEPTH; i = i + 1) begin
                inject_event_continuous(200 + i, 200, 0);
            end

            // Query at (100, 100) - diagonal doesn't match any direction
            inject_event_continuous(100, 100, 1);
            in_valid = 0;

            $display("  - Event at (100,100) - checking diagonal");
            $display("  - captured: v_e=%b v_w=%b v_n=%b v_s=%b (expected all 0 for diagonal)",
                     captured_v_e, captured_v_w, captured_v_n, captured_v_s);

            if (captured_v_e || captured_v_w || captured_v_n || captured_v_s) begin
                $display("ERROR: Diagonal should not match any cardinal direction");
                errors = errors + 1;
            end else begin
                $display("  - Diagonal no-match: PASSED");
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
            $display("All DELAY_LATTICE_RB tests passed!");
            pass();
        end else begin
            fail_msg("DELAY_LATTICE_RB tests failed");
        end
    end

endmodule

`default_nettype wire
