`timescale 1ns/1ps
`default_nettype none

// tb_hot_pixel_rejection: One pixel fires continuously at high rate.
// With LIF_THRESH=4 and DW=0, the LIF spikes every 4 events, the predictor
// tracks the static hot pixel.  Assertions:
//   (a) pred_valid fires at least 10 times (pipeline is alive, not stuck)
//   (b) x_hat stays within 128px of the hot pixel x coordinate (no wild drift)

`include "tb_common_tasks.vh"
module tb_hot_pixel_rejection;
    localparam T_NS = 5;
    localparam XW=10, YW=10, AW=8, DW=0, PW=16;
    localparam [XW-1:0] HOT_X = 200;
    localparam [YW-1:0] HOT_Y = 200;

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=HOT_X; reg [YW-1:0] aer_y=HOT_Y; reg aer_pol=0;
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

    integer t, pred_cnt=0, wild_cnt=0;
    integer ex;

    always @(posedge clk) begin
        if (pred_valid) begin
            pred_cnt <= pred_cnt + 1;
            ex = (x_hat > HOT_X) ? (x_hat - HOT_X) : (HOT_X - x_hat);
            if (ex > 128) wild_cnt <= wild_cnt + 1;
        end
    end

    initial begin
        #(20*T_NS) rst=0;
        // 200 events from same (x,y) — with THRESH=4 this fires 50 times
        for (t=0; t<200; t=t+1) begin
            @(negedge clk); aer_req<=1;
            @(negedge clk); aer_req<=0;
            @(negedge clk);
        end
        repeat(30) @(negedge clk);

        $display("HOT_PIXEL: pred_cnt=%0d wild_cnt=%0d", pred_cnt, wild_cnt);
        if (pred_cnt < 10)
            fail_msg("Hot pixel should produce >=10 pred_valid events");
        if (wild_cnt > 0)
            fail_msg("Hot pixel prediction drifted >128px from hot pixel x");
        pass();
    end
endmodule
`default_nettype wire
