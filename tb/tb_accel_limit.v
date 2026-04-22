`timescale 1ns/1ps
`default_nettype none

`include "tb_common_tasks.vh"
module tb_accel_limit;
    localparam T_NS=10;
    // DW=0: ring buffer depth=1 → Reichardt correlates adjacent LIF spikes,
    // giving valid direction from spike #2.  DW=4 (depth=16) requires 17
    // spikes before rd_v asserts, which never happens in a 60-event run.
    // LIF_THRESH=4 so each tile fires every 4 hits → ~15 spikes / 13 predictions
    // in 60 events, giving the predictor enough data to beat the naive baseline.
    localparam XW=10, YW=10, AW=8, DW=0, PW=16;
    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=20; reg [YW-1:0] aer_y=30; reg aer_pol=0;
    reg [AW-1:0] scan=0; always @(posedge clk) if (!rst) scan<=scan+1'b1;

    wire pred_valid; wire [PW-1:0] x_hat,y_hat; wire [7:0] conf; wire conf_valid;
    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),
                    .LIF_THRESH(4)) dut(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack),.aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid),.x_hat(x_hat),.y_hat(y_hat),.conf(conf),.conf_valid(conf_valid)
    );

    integer t; integer vx=1;
    integer mae_lib=0, mae_base=0; integer b_have=0; integer b_x=0,b_y=0;

    // Dedicated truth registers updated only when a target event is sent so the
    // posedge always block sees the correct ground-truth regardless of pipeline
    // latency between the last event and pred_valid.
    reg [XW-1:0] tgt_x = 20;
    reg [YW-1:0] tgt_y = 30;

    initial begin
        #(20*T_NS) rst=0;
        for (t=0;t<60;t=t+1) begin
            @(negedge clk);
            // Blocking updates so tgt_x/tgt_y are correct before non-blocking drive.
            tgt_x = tgt_x + vx[0+:16];
            tgt_y = tgt_y + (t%2);
            aer_x <= tgt_x; aer_y <= tgt_y; aer_req<=1;
            @(negedge clk); aer_req<=0;
            if (t%2==1 && vx<4) vx=vx+1;
        end
        repeat (60) @(negedge clk);
        if (mae_lib > mae_base) fail_msg("MAE not < baseline with accel");
        if (mae_lib > 520) fail_msg("Abs MAE too high accel");
        pass();
    end

    integer tx, ty, ex, ey, exb, eyb;
    always @(posedge clk) begin
        if (pred_valid) begin
            tx = tgt_x + 1; ty = tgt_y;
            ex = (x_hat>tx)?(x_hat-tx):(tx-x_hat);
            ey = (y_hat>ty)?(y_hat-ty):(ty-y_hat);
            mae_lib <= mae_lib+ex+ey;
            if (b_have) begin
                exb = (b_x>tx)?(b_x-tx):(tx-b_x);
                eyb = (b_y>ty)?(b_y-ty):(ty-b_y);
                mae_base <= mae_base+exb+eyb;
            end
            b_x <= tgt_x; b_y <= tgt_y; b_have <= 1;
        end
    end
endmodule

`default_nettype wire
