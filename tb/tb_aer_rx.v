`timescale 1ns/1ps
`default_nettype none

// tb_aer_rx: Unit testbench for AER receiver module
// Tests: req/ack handshake timing, event parsing, edge cases
// Edge cases: back-to-back events, delayed ack (sustained req), reset during transaction

`include "tb_common_tasks.vh"
module tb_aer_rx;
    localparam T_NS = 5;  // 200 MHz
    localparam XW = 10, YW = 10;

    reg clk = 0, rst = 1;
    always #(T_NS/2) clk = ~clk;

    // AER interface
    reg aer_req = 0;
    wire aer_ack;
    reg [XW-1:0] aer_x = 0;
    reg [YW-1:0] aer_y = 0;
    reg aer_pol = 0;

    // Internal event interface
    wire ev_valid;
    wire [XW-1:0] ev_x;
    wire [YW-1:0] ev_y;
    wire ev_pol;

    // DUT instantiation
    aer_rx #(.XW(XW), .YW(YW)) dut (
        .clk(clk), .rst(rst),
        .aer_req(aer_req), .aer_ack(aer_ack),
        .aer_x(aer_x), .aer_y(aer_y), .aer_pol(aer_pol),
        .ev_valid(ev_valid), .ev_x(ev_x), .ev_y(ev_y), .ev_pol(ev_pol)
    );

    // Test counters
    integer test_num = 0;
    integer errors = 0;

    // Helper task: check expected values
    task check_event;
        input [XW-1:0] exp_x;
        input [YW-1:0] exp_y;
        input exp_pol;
        input exp_valid;
        input exp_ack;
        begin
            if (ev_valid !== exp_valid) begin
                $display("ERROR: ev_valid=%b, expected=%b", ev_valid, exp_valid);
                errors = errors + 1;
            end
            if (aer_ack !== exp_ack) begin
                $display("ERROR: aer_ack=%b, expected=%b", aer_ack, exp_ack);
                errors = errors + 1;
            end
            if (exp_valid && ev_valid) begin
                if (ev_x !== exp_x) begin
                    $display("ERROR: ev_x=%d, expected=%d", ev_x, exp_x);
                    errors = errors + 1;
                end
                if (ev_y !== exp_y) begin
                    $display("ERROR: ev_y=%d, expected=%d", ev_y, exp_y);
                    errors = errors + 1;
                end
                if (ev_pol !== exp_pol) begin
                    $display("ERROR: ev_pol=%b, expected=%b", ev_pol, exp_pol);
                    errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        $display("=== AER_RX Unit Testbench ===");
        $display("");

        // Release reset
        #(10*T_NS) rst = 0;
        @(negedge clk);

        // ============================================================
        // TEST 1: Basic req/ack handshake timing
        // ============================================================
        test_num = 1;
        $display("TEST %0d: Basic req/ack handshake timing", test_num);

        // Verify idle state
        check_event(0, 0, 0, 1'b0, 1'b0);
        $display("  - Idle state verified: ack=0, valid=0");

        // Assert request with event data
        aer_x = 100;
        aer_y = 200;
        aer_pol = 1;
        @(negedge clk);
        aer_req = 1;

        // Wait one clock - ack should assert
        @(negedge clk);
        check_event(100, 200, 1, 1'b1, 1'b1);
        $display("  - After req: ack=1, valid=1, data latched correctly");

        // Deassert request
        aer_req = 0;
        @(negedge clk);
        check_event(0, 0, 0, 1'b0, 1'b0);
        $display("  - After req deassert: ack=0, valid=0");
        $display("TEST %0d: PASSED", test_num);
        $display("");

        // ============================================================
        // TEST 2: Event parsing with different data values
        // ============================================================
        test_num = 2;
        $display("TEST %0d: Event parsing with various data values", test_num);

        // Test min values
        aer_x = 0;
        aer_y = 0;
        aer_pol = 0;
        @(negedge clk);
        aer_req = 1;
        @(negedge clk);
        check_event(0, 0, 0, 1'b1, 1'b1);
        $display("  - Min values (0,0,0): PASSED");
        aer_req = 0;
        @(negedge clk);

        // Test max values
        aer_x = (1 << XW) - 1;  // 1023
        aer_y = (1 << YW) - 1;  // 1023
        aer_pol = 1;
        @(negedge clk);
        aer_req = 1;
        @(negedge clk);
        check_event((1 << XW) - 1, (1 << YW) - 1, 1, 1'b1, 1'b1);
        $display("  - Max values (1023,1023,1): PASSED");
        aer_req = 0;
        @(negedge clk);

        // Test mid values
        aer_x = 512;
        aer_y = 384;
        aer_pol = 0;
        @(negedge clk);
        aer_req = 1;
        @(negedge clk);
        check_event(512, 384, 0, 1'b1, 1'b1);
        $display("  - Mid values (512,384,0): PASSED");
        aer_req = 0;
        @(negedge clk);

        $display("TEST %0d: PASSED", test_num);
        $display("");

        // ============================================================
        // TEST 3: Back-to-back events (consecutive requests)
        // ============================================================
        test_num = 3;
        $display("TEST %0d: Back-to-back events", test_num);

        // Send 5 consecutive events with minimal gap
        begin : back_to_back_block
            integer i;
            for (i = 0; i < 5; i = i + 1) begin
                aer_x = 10 + i * 10;
                aer_y = 20 + i * 10;
                aer_pol = i[0];
                @(negedge clk);
                aer_req = 1;
                @(negedge clk);
                // Verify event captured
                if (ev_valid !== 1'b1 || ev_x !== (10 + i * 10) || ev_y !== (20 + i * 10)) begin
                    $display("ERROR: Back-to-back event %0d not captured correctly", i);
                    errors = errors + 1;
                end
                aer_req = 0;
                @(negedge clk);  // Gap cycle
            end
        end

        $display("  - 5 back-to-back events captured correctly");
        $display("TEST %0d: PASSED", test_num);
        $display("");

        // ============================================================
        // TEST 4: Delayed ack (sustained request)
        // ============================================================
        test_num = 4;
        $display("TEST %0d: Sustained request (delayed handshake completion)", test_num);

        aer_x = 300;
        aer_y = 400;
        aer_pol = 1;
        @(negedge clk);
        aer_req = 1;

        // Keep req high for multiple cycles
        @(negedge clk);  // Cycle 1 - ack should go high
        if (aer_ack !== 1'b1) begin
            $display("ERROR: ack not asserted on cycle 1");
            errors = errors + 1;
        end
        $display("  - Cycle 1: ack=%b, valid=%b", aer_ack, ev_valid);

        @(negedge clk);  // Cycle 2 - ack should stay high while req high
        if (aer_ack !== 1'b1) begin
            $display("ERROR: ack not sustained on cycle 2");
            errors = errors + 1;
        end
        $display("  - Cycle 2: ack=%b, valid=%b (req still high)", aer_ack, ev_valid);

        @(negedge clk);  // Cycle 3
        $display("  - Cycle 3: ack=%b, valid=%b (req still high)", aer_ack, ev_valid);

        @(negedge clk);  // Cycle 4
        $display("  - Cycle 4: ack=%b, valid=%b (req still high)", aer_ack, ev_valid);

        // Now deassert req
        aer_req = 0;
        @(negedge clk);
        if (aer_ack !== 1'b0) begin
            $display("ERROR: ack not deasserted after req low");
            errors = errors + 1;
        end
        $display("  - After req deassert: ack=%b, valid=%b", aer_ack, ev_valid);

        $display("TEST %0d: PASSED", test_num);
        $display("");

        // ============================================================
        // TEST 5: Reset during transaction
        // ============================================================
        test_num = 5;
        $display("TEST %0d: Reset during active transaction", test_num);

        // Start a transaction
        aer_x = 500;
        aer_y = 600;
        aer_pol = 1;
        @(negedge clk);
        aer_req = 1;
        @(negedge clk);

        // Verify transaction in progress
        if (aer_ack !== 1'b1) begin
            $display("ERROR: transaction not started");
            errors = errors + 1;
        end
        $display("  - Transaction started: ack=%b, valid=%b", aer_ack, ev_valid);

        // Assert reset while req still high
        @(negedge clk);
        rst = 1;
        @(negedge clk);

        // Check that outputs are cleared despite req being high
        if (aer_ack !== 1'b0) begin
            $display("ERROR: ack not cleared by reset");
            errors = errors + 1;
        end
        if (ev_valid !== 1'b0) begin
            $display("ERROR: ev_valid not cleared by reset");
            errors = errors + 1;
        end
        if (ev_x !== 0 || ev_y !== 0 || ev_pol !== 0) begin
            $display("ERROR: event data not cleared by reset");
            errors = errors + 1;
        end
        $display("  - After reset (req still high): ack=%b, valid=%b, ev_x=%d", aer_ack, ev_valid, ev_x);

        // Release reset
        aer_req = 0;
        @(negedge clk);
        rst = 0;
        @(negedge clk);
        $display("  - Reset released, system idle");

        $display("TEST %0d: PASSED", test_num);
        $display("");

        // ============================================================
        // TEST 6: Rapid toggle (stress test)
        // ============================================================
        test_num = 6;
        $display("TEST %0d: Rapid req toggle stress test (100 events)", test_num);

        begin : stress_test
            integer i;
            integer captured;
            reg [YW-1:0] y_val;
            captured = 0;
            for (i = 0; i < 100; i = i + 1) begin
                aer_x = i;
                y_val = i * 3;
                aer_y = y_val;
                aer_pol = i[0];
                @(negedge clk);
                aer_req = 1;
                @(negedge clk);
                if (ev_valid && ev_x == i) captured = captured + 1;
                aer_req = 0;
                // Minimal gap
            end
            $display("  - Captured %0d/100 events", captured);
            if (captured != 100) begin
                $display("ERROR: missed %0d events", 100 - captured);
                errors = errors + 1;
            end
        end

        $display("TEST %0d: PASSED", test_num);
        $display("");

        // ============================================================
        // SUMMARY
        // ============================================================
        $display("=== TEST SUMMARY ===");
        $display("Tests run: %0d", test_num);
        $display("Errors: %0d", errors);
        $display("");

        if (errors == 0) begin
            $display("All AER_RX handshake and edge case tests passed!");
            pass();
        end else begin
            fail_msg("AER_RX tests failed");
        end
    end
endmodule

`default_nettype wire
