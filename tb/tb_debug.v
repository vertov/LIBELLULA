`timescale 1ns/1ps
`default_nettype none

module tb_debug;
    localparam T_NS = 5;
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

    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW)) dut(
        .clk(clk), .rst(rst),
        .aer_req(aer_req), .aer_ack(aer_ack),
        .aer_x(aer_x), .aer_y(aer_y), .aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid), .x_hat(x_hat), .y_hat(y_hat),
        .conf(conf), .conf_valid(conf_valid)
    );

    defparam dut.u_lif.LEAK_SHIFT = 0;
    defparam dut.u_lif.THRESH = 1;
    defparam dut.u_bg.COUNT_TH = 0;

    function [AW-1:0] hash;
        input [XW-1:0] x; input [YW-1:0] y;
        begin hash = (x ^ y) & ((1<<AW)-1); end
    endfunction

    integer i, pred_count = 0;

    initial begin
        #(20*T_NS) rst = 0;

        $display("Debug: Sending 10 events with CHANGING coordinates (motion pattern)");

        for (i = 0; i < 10; i = i + 1) begin
            // Different coordinates for each event (motion)
            aer_x = 100 + i;
            aer_y = 100;

            // Update scan to match new coordinates
            scan = hash(aer_x, aer_y);
            $display("Event %0d: x=%0d, scan=%0d", i, aer_x, scan);

            // Pre-hold scan, then send event (like px300)
            repeat (4) @(negedge clk);
            aer_req = 1;
            @(negedge clk);
            aer_req = 0;

            // Wait for pipeline to process (667 cycles like tb_px_bound_300hz for 300Hz)
            repeat (667) @(posedge clk);
        end

        repeat (100) @(posedge clk);
        $display("Total predictions seen: %0d", pred_count);
        $finish;
    end

    // Monitor predictions
    always @(posedge clk) begin
        if (pred_valid) begin
            $display("  PRED_VALID: x_hat=%0d y_hat=%0d conf=%0d", x_hat, y_hat, conf);
            pred_count <= pred_count + 1;
        end
    end
endmodule

`default_nettype wire
