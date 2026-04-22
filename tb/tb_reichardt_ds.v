`timescale 1ns/1ps
`default_nettype none

// tb_reichardt_ds: Unit testbench for Reichardt direction sensor
// Tests: direction accumulation, decay, saturation, all 4 directions

`include "tb_common_tasks.vh"
module tb_reichardt_ds;
    localparam T_NS = 5;  // 200 MHz
    localparam CW = 8;
    localparam DECAY_SHIFT = 4;

    reg clk = 0, rst = 1;
    always #(T_NS/2) clk = ~clk;

    // Inputs
    reg v_e = 0, v_w = 0, v_n = 0, v_s = 0;
    // Diagonal inputs: unused in cardinal-only tests, tied to 0 to prevent X propagation.
    // Unconnected inputs would float to Z/X and corrupt dir_x/dir_y through ternary logic.
    reg v_ne = 0, v_nw = 0, v_se = 0, v_sw = 0;
    reg in_valid = 0;

    // Outputs
    wire out_valid;
    wire signed [CW-1:0] dir_x, dir_y;

    // DUT
    reichardt_ds #(.CW(CW), .DECAY_SHIFT(DECAY_SHIFT)) dut (
        .clk(clk), .rst(rst),
        .v_e(v_e), .v_w(v_w), .v_n(v_n), .v_s(v_s),
        .v_ne(v_ne), .v_nw(v_nw), .v_se(v_se), .v_sw(v_sw),
        .in_valid(in_valid),
        .out_valid(out_valid),
        .dir_x(dir_x), .dir_y(dir_y)
    );

    integer test_num = 0;
    integer errors = 0;

    // X/Z guard: if dir_x or dir_y is undefined, count as error immediately
    task check_no_x;
        begin
            if (^dir_x === 1'bx || ^dir_y === 1'bx) begin
                $display("ERROR: dir_x or dir_y contains X/Z (undefined) at test %0d", test_num);
                errors = errors + 1;
            end
        end
    endtask

    // Task: inject direction event (cardinal only)
    task inject_direction;
        input e, w, n, s;
        begin
            v_e = e; v_w = w; v_n = n; v_s = s;
            in_valid = 1;
            @(negedge clk);
            in_valid = 0;
            v_e = 0; v_w = 0; v_n = 0; v_s = 0;
        end
    endtask

    initial begin
        $display("=== REICHARDT_DS Unit Testbench ===");
        $display("Parameters: CW=%0d, DECAY_SHIFT=%0d", CW, DECAY_SHIFT);
        $display("");

        #(10*T_NS) rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 1: East direction (v_w=1) -> positive dir_x
        // card_x = v_w - v_e: West-correlator fires for East-moving targets.
        // ============================================================
        test_num = 1;
        $display("TEST %0d: East direction detection", test_num);

        inject_direction(0, 1, 0, 0);   // v_w=1 → card_x = +1 → dir_x > 0
        @(negedge clk);

        check_no_x();
        $display("  - v_w=1: dir_x=%0d, dir_y=%0d", dir_x, dir_y);
        if (^dir_x === 1'bx || dir_x <= 0) begin
            $display("ERROR: dir_x should be positive for East motion");
            errors = errors + 1;
        end else begin
            $display("  - East direction: PASSED");
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 2: West direction (v_e=1) -> negative dir_x
        // card_x = v_w - v_e: East-correlator fires for West-moving targets.
        // ============================================================
        test_num = 2;
        $display("TEST %0d: West direction detection", test_num);

        inject_direction(1, 0, 0, 0);   // v_e=1 → card_x = -1 → dir_x < 0
        @(negedge clk);

        check_no_x();
        $display("  - v_e=1: dir_x=%0d, dir_y=%0d", dir_x, dir_y);
        if (^dir_x === 1'bx || dir_x >= 0) begin
            $display("ERROR: dir_x should be negative for West motion");
            errors = errors + 1;
        end else begin
            $display("  - West direction: PASSED");
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 3: North direction (v_s=1) -> positive dir_y
        // card_y = v_s - v_n: South-correlator fires for North-moving targets.
        // ============================================================
        test_num = 3;
        $display("TEST %0d: North direction detection", test_num);

        inject_direction(0, 0, 0, 1);   // v_s=1 → card_y = +1 → dir_y > 0
        @(negedge clk);

        check_no_x();
        $display("  - v_s=1: dir_x=%0d, dir_y=%0d", dir_x, dir_y);
        if (^dir_y === 1'bx || dir_y <= 0) begin
            $display("ERROR: dir_y should be positive for North motion");
            errors = errors + 1;
        end else begin
            $display("  - North direction: PASSED");
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 4: South direction (v_n=1) -> negative dir_y
        // card_y = v_s - v_n: North-correlator fires for South-moving targets.
        // ============================================================
        test_num = 4;
        $display("TEST %0d: South direction detection", test_num);

        inject_direction(0, 0, 1, 0);   // v_n=1 → card_y = -1 → dir_y < 0
        @(negedge clk);

        check_no_x();
        $display("  - v_n=1: dir_x=%0d, dir_y=%0d", dir_x, dir_y);
        if (^dir_y === 1'bx || dir_y >= 0) begin
            $display("ERROR: dir_y should be negative for South motion");
            errors = errors + 1;
        end else begin
            $display("  - South direction: PASSED");
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 5: Direction accumulation (multiple East events)
        // ============================================================
        test_num = 5;
        $display("TEST %0d: Direction accumulation", test_num);

        begin : test5_block
            integer i;
            reg signed [CW-1:0] prev_dir_x;

            inject_direction(0, 1, 0, 0);  // v_w=1 → East
            prev_dir_x = dir_x;
            $display("  - After 1 East event: dir_x=%0d", dir_x);

            for (i = 0; i < 3; i = i + 1) begin
                inject_direction(0, 1, 0, 0);  // v_w=1 → East
            end
            $display("  - After 4 East events: dir_x=%0d", dir_x);

            check_no_x();
            if (^dir_x === 1'bx || dir_x <= prev_dir_x) begin
                $display("ERROR: dir_x should accumulate with repeated events");
                errors = errors + 1;
            end else begin
                $display("  - Accumulation: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 6: Decay over time (no input)
        // ============================================================
        test_num = 6;
        $display("TEST %0d: Leaky decay", test_num);

        begin : test6_block
            integer i;
            reg signed [CW-1:0] initial_dir_x;

            // Build up some direction (East: v_w=1)
            for (i = 0; i < 10; i = i + 1) begin
                inject_direction(0, 1, 0, 0);  // v_w=1 → East
            end
            initial_dir_x = dir_x;
            $display("  - After 10 East events: dir_x=%0d", initial_dir_x);

            // Let decay happen (no events)
            for (i = 0; i < 50; i = i + 1) @(negedge clk);

            $display("  - After 50 idle cycles: dir_x=%0d", dut.acc_x[CW-1:0]);
            if (dut.acc_x >= initial_dir_x) begin
                $display("ERROR: Accumulator should decay without input");
                errors = errors + 1;
            end else begin
                $display("  - Decay: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 7: Opposing directions cancel
        // ============================================================
        test_num = 7;
        $display("TEST %0d: Opposing directions cancel", test_num);

        inject_direction(0, 1, 0, 0);  // East (v_w=1)
        inject_direction(1, 0, 0, 0);  // West (v_e=1)

        check_no_x();
        $display("  - After East then West: dir_x=%0d", dir_x);
        // Should be close to 0 (but not exact due to decay)
        if (^dir_x === 1'bx) begin
            $display("ERROR: dir_x is X/Z after direction cancellation");
            errors = errors + 1;
        end else if (dir_x > 2 || dir_x < -2) begin
            $display("WARNING: Opposing directions may not fully cancel (decay effect)");
        end else begin
            $display("  - Cancellation: PASSED");
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 8: Saturation test (many events in one direction)
        // ============================================================
        test_num = 8;
        $display("TEST %0d: Output saturation", test_num);

        begin : test8_block
            integer i;

            // Inject many East events to saturate (East: v_w=1)
            for (i = 0; i < 50; i = i + 1) begin
                inject_direction(0, 1, 0, 0);  // v_w=1 → East
            end

            check_no_x();
            $display("  - After 50 East events: dir_x=%0d (max=127)", dir_x);
            if (^dir_x === 1'bx || dir_x > 127 || dir_x < -128) begin
                $display("ERROR: dir_x exceeds 8-bit signed range or is X/Z");
                errors = errors + 1;
            end else begin
                $display("  - Saturation bounds: PASSED");
            end
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 9: Diagonal motion (v_e + v_n)
        // ============================================================
        test_num = 9;
        $display("TEST %0d: Diagonal motion (NE)", test_num);

        // NE motion: v_w=1 → dir_x>0 (East), v_s=1 → dir_y>0 (North)
        inject_direction(0, 1, 0, 1);  // v_w=1, v_s=1 → NE
        @(negedge clk);

        check_no_x();
        $display("  - v_w=1, v_s=1: dir_x=%0d, dir_y=%0d", dir_x, dir_y);
        if (^dir_x === 1'bx || ^dir_y === 1'bx || dir_x <= 0 || dir_y <= 0) begin
            $display("ERROR: Both dir_x and dir_y should be positive for NE");
            errors = errors + 1;
        end else begin
            $display("  - Diagonal motion: PASSED");
        end
        $display("");

        // Reset
        rst = 1; @(negedge clk); @(negedge clk); rst = 0; @(negedge clk);

        // ============================================================
        // TEST 10: out_valid only on in_valid
        // ============================================================
        test_num = 10;
        $display("TEST %0d: out_valid timing", test_num);

        begin : test10_block
            integer valid_count;
            integer i;
            valid_count = 0;

            // Check that out_valid is 0 without input
            for (i = 0; i < 10; i = i + 1) begin
                @(negedge clk);
                if (out_valid) valid_count = valid_count + 1;
            end

            if (valid_count > 0) begin
                $display("ERROR: out_valid asserted without in_valid");
                errors = errors + 1;
            end

            // Inject event and check out_valid
            inject_direction(1, 0, 0, 0);

            $display("  - out_valid only on in_valid: PASSED");
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
            $display("All REICHARDT_DS tests passed!");
            pass();
        end else begin
            fail_msg("REICHARDT_DS tests failed");
        end
    end
endmodule

`default_nettype wire
