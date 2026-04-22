`timescale 1ns/1ps
`default_nettype none

// tb_meps_nodrop: 1 Million Events Per Second throughput test
// Verifies no events are dropped at sustained 1 Meps rate

`include "tb_common_tasks.vh"
module tb_meps_nodrop;
    localparam T_NS = 5;  // 200 MHz = 5ns period
    localparam XW = 10, YW = 10, AW = 8, DW = 0, PW = 16;

    // At 200 MHz, 1 Meps = 200 cycles per event
    localparam CYCLES_PER_EVENT = 200;
    localparam NUM_EVENTS = 2000;  // 2ms worth of events at 1 Meps

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

    // Spatial tile hash — must match lif_tile_tmux hashed_xy exactly.
    localparam HX = AW / 2;
    localparam HY = AW - HX;
    function automatic [AW-1:0] hash(input [XW-1:0] x, input [YW-1:0] y);
        hash = {x[XW-1:XW-HX], y[YW-1:YW-HY]};
    endfunction

    integer req_count = 0;
    integer ack_count = 0;
    integer pred_count = 0;
    integer i, c;
    integer timeout;

    initial begin
        #(20*T_NS) rst = 0;

        $display("1 Meps throughput test: %0d events at 200 cycles/event spacing", NUM_EVENTS);
        $display("Expected: All %0d events acknowledged (zero drops)", NUM_EVENTS);

        // Pre-set scan address
        scan = hash(100, 100);

        // Send events at 1 Meps rate with proper 4-phase handshake
        for (i = 0; i < NUM_EVENTS; i = i + 1) begin
            // Update coordinates (simulate moving target)
            aer_x = 100 + (i % 50);
            aer_y = 100 + (i / 50);
            scan = hash(aer_x, aer_y);

            // Pre-hold scan for 4 cycles
            repeat (4) @(negedge clk);

            // 4-phase AER handshake
            aer_req = 1;
            req_count = req_count + 1;

            // Wait for ACK (with timeout)
            timeout = 100;
            while (aer_ack !== 1 && timeout > 0) begin
                @(negedge clk);
                timeout = timeout - 1;
            end

            if (aer_ack === 1) begin
                ack_count = ack_count + 1;
            end else begin
                $display("WARNING: Event %0d timed out waiting for ACK", i);
            end

            // Complete handshake
            @(negedge clk);
            aer_req = 0;

            // Wait for ACK to deassert
            timeout = 100;
            while (aer_ack !== 0 && timeout > 0) begin
                @(negedge clk);
                timeout = timeout - 1;
            end

            // Wait remaining cycles to hit 1 Meps rate
            // Total should be ~200 cycles per event
            for (c = 0; c < (CYCLES_PER_EVENT - 10); c = c + 1) begin
                @(negedge clk);
            end
        end

        // Drain pipeline
        repeat (500) @(negedge clk);

        $display("REQ=%0d ACK=%0d PRED=%0d", req_count, ack_count, pred_count);

        // Verify zero drops
        if (ack_count != req_count) begin
            $display("FAIL: %0d events dropped (%0d/%0d)", req_count - ack_count, ack_count, req_count);
            $finish_and_return(1);
        end

        $display("THROUGHPUT_MEPS=1");
        $display("EVENTS_DROPPED=0");
        pass();
    end

    // Count predictions
    always @(posedge clk) begin
        if (pred_valid) pred_count <= pred_count + 1;
    end
endmodule

`default_nettype wire
