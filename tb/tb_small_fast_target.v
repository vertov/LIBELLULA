`timescale 1ns/1ps
`default_nettype none

// tb_small_fast_target: 1-pixel target at 8px/step — small and fast.
// With LIF_THRESH=4 and DW=0: 4 events per tile → fire → pipeline tracks.
// Starting at x=8, +8px/step, y=10 constant. Sends 32 events.
// Tiles visited: 0(x=8..56), 1(x=64..120), 2(x=128..184), 3(x=192..248)
//   each tile gets 8 events → fires twice per tile → many pred_valid events.
// Asserts: pred_valid fires at least 4 times.

`include "tb_common_tasks.vh"
module tb_small_fast_target;
    localparam T_NS = 5;
    localparam XW=10, YW=10, AW=8, DW=0, PW=16;

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=8; reg [YW-1:0] aer_y=10; reg aer_pol=0;
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

    reg [XW-1:0] tgt_x = 8;
    integer t, pred_cnt=0;

    always @(posedge clk)
        if (pred_valid) pred_cnt <= pred_cnt + 1;

    initial begin
        #(20*T_NS) rst=0;
        tgt_x = 8;
        for (t=0; t<32; t=t+1) begin
            @(negedge clk);
            tgt_x = tgt_x + 8;
            aer_x <= tgt_x; aer_req<=1;
            @(negedge clk); aer_req<=0;
            @(negedge clk);
        end
        repeat(20) @(negedge clk);

        $display("SMALL_FAST: pred_cnt=%0d (expected >=4)", pred_cnt);
        if (pred_cnt < 4)
            fail_msg("Small fast target should produce >=4 pred_valid events");
        pass();
    end
endmodule
`default_nettype wire
