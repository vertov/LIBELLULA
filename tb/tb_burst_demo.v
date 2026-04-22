`timescale 1ns/1ps
`default_nettype none

// tb_burst_demo: Burst detection timing test
// Verifies burst_gate detects event bursts within 100 cycles

`include "tb_common_tasks.vh"
module tb_burst_demo;
    localparam T_NS = 5;  // 200 MHz
    localparam XW = 10, YW = 10, AW = 8, DW = 0, PW = 16;
    localparam BURST_WINDOW = 16;  // Default burst gate window

    reg clk = 0, rst = 1;
    always #(T_NS/2) clk = ~clk;

    reg aer_req = 0;
    wire aer_ack;
    reg [XW-1:0] aer_x = 50;
    reg [YW-1:0] aer_y = 50;
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

    // Permissive settings for quick detection
    defparam dut.u_lif.LEAK_SHIFT = 0;
    defparam dut.u_lif.THRESH = 1;
    // Keep burst gate threshold at 3 - this is what we're testing!

    // Spatial tile hash — must match lif_tile_tmux hashed_xy exactly.
    localparam HX = AW / 2;
    localparam HY = AW - HX;
    function automatic [AW-1:0] hash(input [XW-1:0] x, input [YW-1:0] y);
        hash = {x[XW-1:XW-HX], y[YW-1:YW-HY]};
    endfunction

    // AER request with proper scan pre-hold (matching tb_px_bound_300hz)
    task send_event;
        begin
            scan = hash(aer_x, aer_y);
            repeat (4) @(negedge clk);  // Pre-hold scan for LIF
            aer_req = 1;
            @(negedge clk);
            aer_req = 0;
            @(negedge clk);
        end
    endtask

    integer burst_start_cycle;
    integer first_pred_cycle;
    integer detection_latency;
    integer pred_count = 0;
    integer i;
    reg burst_detected = 0;

    initial begin
        #(20*T_NS) rst = 0;

        // Wait a bit, then send a burst of events
        repeat (20) @(negedge clk);

        // Record start of burst
        burst_start_cycle = $time / T_NS;
        $display("Burst starts at cycle %0d", burst_start_cycle);

        // Send burst of events using proper handshake
        for (i = 0; i < 8; i = i + 1) begin
            aer_x = 50 + i;
            aer_y = 50;
            send_event();
        end

        // Wait for detection (up to 200 cycles)
        for (i = 0; i < 200 && !burst_detected; i = i + 1) begin
            @(negedge clk);
        end

        if (!burst_detected) begin
            fail_msg("Burst not detected within 100 cycles");
        end

        $display("BURST_DETECTION_LATENCY=%0d cycles", detection_latency);

        if (detection_latency > 100) begin
            fail_msg("Burst detection took > 100 cycles");
        end

        pass();
    end

    // Monitor for first prediction after burst
    always @(posedge clk) begin
        if (pred_valid && !burst_detected) begin
            first_pred_cycle = $time / T_NS;
            detection_latency = first_pred_cycle - burst_start_cycle;
            burst_detected <= 1;
            pred_count <= pred_count + 1;
            $display("First prediction at cycle %0d (latency=%0d)", first_pred_cycle, detection_latency);
        end else if (pred_valid) begin
            pred_count <= pred_count + 1;
        end
    end
endmodule

`default_nettype wire
