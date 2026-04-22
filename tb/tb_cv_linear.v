`timescale 1ns/1ps
`default_nettype none

`include "tb_common_tasks.vh"
module tb_cv_linear;
    localparam T_NS=10; // 100 MHz
    localparam XW=10, YW=10, AW=8, DW=4, PW=16;
    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=10; reg [YW-1:0] aer_y=20; reg aer_pol=0;
    reg [AW-1:0] scan=0;
    always @(posedge clk) if (!rst) scan<=scan+1'b1;

    wire pred_valid; wire [PW-1:0] x_hat,y_hat; wire [7:0] conf; wire conf_valid;

    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW)) dut(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack),.aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid),.x_hat(x_hat),.y_hat(y_hat),.conf(conf),.conf_valid(conf_valid)
    );

    // Baseline: last sample hold of x,y at pred cadence
    reg          b_have=0;
    reg [PW-1:0] b_x=0, b_y=0;
    wire [PW-1:0] truth_x = aer_x + 1;
    wire [PW-1:0] truth_y = aer_y;

    integer mae_lib=0, mae_base=0, N=0;

    initial begin
        #(20*T_NS) rst=0;
        // 64 events with vx=+1
        repeat (64) begin
            @(negedge clk); aer_x<=aer_x+1; aer_req<=1;
            @(negedge clk); aer_req<=0;
        end
        repeat (50) @(negedge clk);
        if (mae_lib > mae_base) fail_msg("Libellula MAE not < baseline");
        if (mae_lib > 80)       fail_msg("Absolute MAE too high");
        pass();
    end

    integer ex, ey, exb, eyb;
    always @(posedge clk) begin
        if (pred_valid) begin
            ex = (x_hat>truth_x) ? (x_hat-truth_x):(truth_x-x_hat);
            ey = (y_hat>truth_y) ? (y_hat-truth_y):(truth_y-y_hat);
            mae_lib <= mae_lib + ex + ey; N<=N+1;
            // Baseline sample
            if (b_have) begin
                exb = (b_x>truth_x) ? (b_x-truth_x):(truth_x-b_x);
                eyb = (b_y>truth_y) ? (b_y-truth_y):(truth_y-b_y);
                mae_base <= mae_base + exb + eyb;
            end
            b_x <= aer_x; b_y<=aer_y; b_have<=1;
        end
    end
endmodule

`default_nettype wire
