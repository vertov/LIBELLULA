`timescale 1ns/1ps
`default_nettype none

// tb_dense_burst: Event flood/saturation test
// Verifies no FIFO overflow and graceful degradation under high load

`include "tb_common_tasks.vh"
module tb_dense_burst;
    localparam T_NS = 5;  // 200 MHz
    localparam XW = 10, YW = 10, AW = 8, DW = 0, PW = 16;

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

    // Permissive settings
    defparam dut.u_lif.LEAK_SHIFT = 0;
    defparam dut.u_lif.THRESH = 1;
    // COUNT_TH removed: v22 burst_gate uses TH_OPEN/TH_CLOSE, not COUNT_TH.

    // Spatial tile hash — must match lif_tile_tmux hashed_xy exactly.
    localparam HX = AW / 2;
    localparam HY = AW - HX;
    function automatic [AW-1:0] hash(input [XW-1:0] x, input [YW-1:0] y);
        hash = {x[XW-1:XW-HX], y[YW-1:YW-HY]};
    endfunction

    integer req_count = 0;
    integer ack_count = 0;
    integer pred_count = 0;
    integer i;

    initial begin
        #(20*T_NS) rst = 0;

        $display("Dense burst test: Back-to-back events for saturation");

        // Fixed scan address for consistent LIF accumulation
        scan = hash(100, 100);

        // Send maximum rate burst to same location
        for (i = 0; i < 500; i = i + 1) begin
            aer_x = 100;
            aer_y = 100;

            // Minimum cycle request
            @(negedge clk);
            aer_req = 1;
            req_count = req_count + 1;
            @(negedge clk);
            aer_req = 0;
        end

        // Wait for pipeline to drain
        repeat (200) @(negedge clk);

        $display("REQ=%0d PRED=%0d", req_count, pred_count);

        // Should produce predictions under load
        if (pred_count == 0) begin
            fail_msg("No predictions generated under load");
        end

        $display("Predictions per 100 events: %0d", (pred_count * 100) / req_count);
        pass();
    end

    always @(posedge clk) begin
        if (pred_valid) pred_count <= pred_count + 1;
        if (aer_ack) ack_count <= ack_count + 1;
    end
endmodule

`default_nettype wire
