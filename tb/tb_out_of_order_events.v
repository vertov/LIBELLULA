`timescale 1ns/1ps
`default_nettype none

// tb_out_of_order_events: Events with non-sequential x coordinates.
// The pipeline treats each event independently by its hash — it has no
// concept of "order" — so all events must be acknowledged and the pipeline
// must remain live.  Each x goes to a different tile; no tile accumulates
// enough hits to reach THRESH so pred_valid must stay 0.

`include "tb_common_tasks.vh"
module tb_out_of_order_events;
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

    // 30 distinct tiles (64-px wide), one event each — never reaches THRESH=16
    // Tiles 0..14 at x=0,64,128,...,896 and tiles 0..14 at x=32,96,160,...
    localparam N = 30;
    reg [XW-1:0] xs [0:N-1];
    integer i, ack_fail=0, pred_count=0;

    initial begin
        xs[ 0]=  0; xs[ 1]=960; xs[ 2]=128; xs[ 3]=832;
        xs[ 4]=256; xs[ 5]=704; xs[ 6]=384; xs[ 7]=576;
        xs[ 8]= 64; xs[ 9]=896; xs[10]=192; xs[11]=768;
        xs[12]=320; xs[13]=640; xs[14]=448; xs[15]=512;
        xs[16]= 32; xs[17]=992; xs[18]=160; xs[19]=800;
        xs[20]=288; xs[21]=672; xs[22]=416; xs[23]=544;
        xs[24]= 96; xs[25]=928; xs[26]=224; xs[27]=736;
        xs[28]=352; xs[29]=608;

        #(20*T_NS) rst=0;

        for (i=0; i<N; i=i+1) begin
            @(negedge clk);
            aer_x <= xs[i]; aer_y <= 10; aer_req <= 1;
            @(negedge clk);
            if (!aer_ack) ack_fail = ack_fail + 1;
            aer_req <= 0;
            @(negedge clk);
        end
        repeat(20) @(negedge clk);

        $display("OOO: events=%0d ack_fail=%0d pred=%0d", N, ack_fail, pred_count);
        if (ack_fail > 0)
            fail_msg("aer_ack missing for out-of-order events");
        if (pred_count > 0)
            fail_msg("pred_valid fired unexpectedly (each tile < THRESH=16)");
        pass();
    end

    always @(posedge clk)
        if (pred_valid) pred_count <= pred_count + 1;
endmodule
`default_nettype wire
