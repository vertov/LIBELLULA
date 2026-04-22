`timescale 1ns/1ps
`default_nettype none

// tb_coverage: Pipeline stage coverage check.
// Runs a comprehensive stimulus that exercises all pipeline stages and verifies
// each produces at least one output:
//   ev_v  (aer_rx)     : aer_ack count
//   lif_v (lif_tile)   : pred_valid implies LIF fired at some point
//   pred_v (end-to-end): pred_valid count
//
// Also verifies polarity is passed through (both pol=0 and pol=1 events accepted).

`include "tb_common_tasks.vh"
module tb_coverage;
    localparam T_NS = 5;
    localparam XW=10, YW=10, AW=8, DW=0, PW=16;

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=10; reg [YW-1:0] aer_y=10; reg aer_pol=0;
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

    integer t, ack_cnt=0, pred_cnt=0;
    integer pol0_cnt=0, pol1_cnt=0;

    always @(posedge clk) begin
        if (!rst) begin
            if (aer_ack)  ack_cnt  <= ack_cnt  + 1;
            if (pred_valid) pred_cnt <= pred_cnt + 1;
        end
    end

    initial begin
        #(20*T_NS) rst=0;

        // 40 events: moving target, alternating polarity
        for (t=0; t<40; t=t+1) begin
            @(negedge clk);
            aer_x   <= 10 + t * 4;
            aer_y   <= 10;
            aer_pol <= t[0];
            aer_req <= 1;
            @(negedge clk); aer_req<=0;
            if (aer_ack) begin
                if (t[0]) pol1_cnt = pol1_cnt + 1;
                else       pol0_cnt = pol0_cnt + 1;
            end
            @(negedge clk);
        end
        repeat(30) @(negedge clk);

        $display("COVERAGE: ack=%0d pred=%0d pol0=%0d pol1=%0d",
                 ack_cnt, pred_cnt, pol0_cnt, pol1_cnt);

        // AER RX coverage: all 40 events acknowledged
        if (ack_cnt != 40)
            fail_msg("aer_rx: not all events acknowledged");
        // End-to-end coverage: at least one prediction produced
        if (pred_cnt == 0)
            fail_msg("Pipeline end-to-end: no pred_valid — LIF/Reichardt/gate not exercised");
        // Polarity coverage: both polarities accepted
        if (pol0_cnt == 0)
            fail_msg("pol=0 events never acknowledged");
        if (pol1_cnt == 0)
            fail_msg("pol=1 events never acknowledged");
        pass();
    end
endmodule
`default_nettype wire
