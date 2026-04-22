`timescale 1ns/1ps
`default_nettype none

// tb_aer_timestamp_order: Inject events with non-monotonic x/y coordinates.
// The pipeline must not hang or crash regardless of event ordering.
// Asserts: (a) aer_ack follows aer_req for every event, (b) no pipeline deadlock.

`include "tb_common_tasks.vh"
module tb_aer_timestamp_order;
    localparam T_NS = 5;
    localparam XW=10, YW=10, AW=8, DW=0, PW=16;

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=0; reg [YW-1:0] aer_y=0; reg aer_pol=0;
    reg [AW-1:0] scan=0; always @(posedge clk) if (!rst) scan<=scan+1'b1;

    wire pred_valid; wire [PW-1:0] x_hat,y_hat; wire [7:0] conf; wire conf_valid;
    wire [1:0] tid_unused;
    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW)) dut(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid),.x_hat(x_hat),.y_hat(y_hat),
        .conf(conf),.conf_valid(conf_valid),.track_id(tid_unused)
    );

    // Non-monotonic coordinate sequence (deterministic)
    localparam N = 40;
    reg [XW-1:0] xs [0:N-1];
    reg [YW-1:0] ys [0:N-1];

    integer i, ack_ok, ack_fail;

    initial begin
        // Build non-monotonic sequence: interleave high/low/mid values
        xs[ 0]=500; ys[ 0]=300;  xs[ 1]= 50; ys[ 1]= 20;
        xs[ 2]=900; ys[ 2]=800;  xs[ 3]=100; ys[ 3]=  5;
        xs[ 4]=300; ys[ 4]=600;  xs[ 5]=700; ys[ 5]=200;
        xs[ 6]=  0; ys[ 6]=999;  xs[ 7]=999; ys[ 7]=  0;
        xs[ 8]=450; ys[ 8]=450;  xs[ 9]=  1; ys[ 9]=998;
        xs[10]=600; ys[10]=100;  xs[11]=150; ys[11]=850;
        xs[12]=800; ys[12]=400;  xs[13]= 25; ys[13]=975;
        xs[14]=350; ys[14]=350;  xs[15]=650; ys[15]=650;
        xs[16]=200; ys[16]=700;  xs[17]=750; ys[17]=250;
        xs[18]=120; ys[18]=880;  xs[19]=880; ys[19]=120;
        xs[20]=500; ys[20]=500;  xs[21]=  0; ys[21]=  0;
        xs[22]=512; ys[22]=512;  xs[23]=256; ys[23]=256;
        xs[24]=768; ys[24]=768;  xs[25]=384; ys[25]=384;
        xs[26]=640; ys[26]=480;  xs[27]=320; ys[27]=240;
        xs[28]=960; ys[28]= 40;  xs[29]= 40; ys[29]=960;
        xs[30]=100; ys[30]=900;  xs[31]=900; ys[31]=100;
        xs[32]=300; ys[32]=700;  xs[33]=700; ys[33]=300;
        xs[34]=200; ys[34]=800;  xs[35]=800; ys[35]=200;
        xs[36]=450; ys[36]=550;  xs[37]=550; ys[37]=450;
        xs[38]=  5; ys[38]=995;  xs[39]=995; ys[39]=  5;

        ack_ok = 0; ack_fail = 0;
        #(20*T_NS) rst=0;

        for (i=0; i<N; i=i+1) begin
            @(negedge clk);
            aer_x <= xs[i]; aer_y <= ys[i]; aer_req <= 1;
            @(negedge clk);
            // aer_ack must mirror aer_req within 1 cycle
            if (aer_ack) ack_ok = ack_ok + 1;
            else         ack_fail = ack_fail + 1;
            aer_req <= 0;
            @(negedge clk);
        end
        repeat(20) @(negedge clk);

        $display("ORDER: events=%0d ack_ok=%0d ack_fail=%0d", N, ack_ok, ack_fail);
        if (ack_fail > 0)
            fail_msg("aer_ack did not follow aer_req for all out-of-order events");
        pass();
    end
endmodule
`default_nettype wire
