`timescale 1ns/1ps
`default_nettype none

// tb_duplicate_event_handling: Same (x,y,pol) event repeated 20 times.
// With LIF_THRESH=4 and DW=0: spikes at events 4, 8, 12, 16, 20 (5 spikes).
// Burst gate opens at spike 2 (BG_TH_OPEN=2 default).
// Asserts: pred_valid fires at least 3 times; predictions near the hot pixel.

`include "tb_common_tasks.vh"
module tb_duplicate_event_handling;
    localparam T_NS = 5;
    localparam XW=10, YW=10, AW=8, DW=0, PW=16;
    localparam [XW-1:0] DUP_X = 256;
    localparam [YW-1:0] DUP_Y = 256;

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=DUP_X; reg [YW-1:0] aer_y=DUP_Y; reg aer_pol=0;
    reg [AW-1:0] scan=0; always @(posedge clk) if (!rst) scan<=scan+1'b1;

    wire pred_valid; wire [PW-1:0] x_hat,y_hat; wire [7:0] conf; wire conf_valid;
    wire [1:0] tid_unused;
    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),
                    .LIF_THRESH(4)) dut(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid),.x_hat(x_hat),.y_hat(y_hat),
        .conf(conf),.conf_valid(conf_valid),.track_id(tid_unused)
    );

    integer t, pred_cnt=0;

    always @(posedge clk)
        if (pred_valid) pred_cnt <= pred_cnt + 1;

    initial begin
        #(20*T_NS) rst=0;
        for (t=0; t<20; t=t+1) begin
            @(negedge clk); aer_req<=1;
            @(negedge clk); aer_req<=0;
            @(negedge clk);
        end
        repeat(20) @(negedge clk);

        $display("DUPLICATE: pred_cnt=%0d (expected >=3)", pred_cnt);
        if (pred_cnt < 3)
            fail_msg("Duplicate events should produce >=3 pred_valid (5 spikes, gate opens at 2)");
        pass();
    end
endmodule
`default_nettype wire
