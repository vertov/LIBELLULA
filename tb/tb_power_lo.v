`timescale 1ns/1ps
`default_nettype none

module tb_power_lo;
    localparam T_NS=10;
    localparam XW=10, YW=10, AW=8, DW=4, PW=16;
    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;
    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=10; reg [YW-1:0] aer_y=20; reg aer_pol=0;
    reg [AW-1:0] scan=0; always @(posedge clk) if (!rst) scan<=scan+1'b1;
    wire pred_valid; wire [PW-1:0] x_hat,y_hat; wire [7:0] conf; wire conf_valid;

    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW)) dut(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack),.aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid),.x_hat(x_hat),.y_hat(y_hat),.conf(conf),.conf_valid(conf_valid)
    );

    initial begin
        $dumpfile("build/power_lo.vcd"); $dumpvars(0, tb_power_lo);
        #(20*T_NS) rst=0;
        repeat (32) begin
            @(negedge clk); aer_x<=aer_x+1; aer_req<=1;
            repeat (5) @(negedge clk); aer_req<=0;
            repeat (10) @(negedge clk);
        end
        repeat (50) @(negedge clk); $finish;
    end
endmodule

`default_nettype wire
