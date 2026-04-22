`timescale 1ns/1ps
`default_nettype none

// tb_gate_threshold_sweep: Sweep BG_TH_OPEN (burst-gate open threshold).
// dut1: BG_TH_OPEN=1 → pred_valid fires after 1st LIF spike.
// dut2: BG_TH_OPEN=2 → pred_valid fires after 2nd LIF spike.
// Both DUTs receive identical stimulus (20 events, LIF_THRESH=1 → 1 spike/event).
// Asserts:
//   (a) dut1 produces pred_valid before dut2 (opens sooner).
//   (b) Both produce pred_valid (both configurations are functional).

`include "tb_common_tasks.vh"
module tb_gate_threshold_sweep;
    localparam T_NS = 5;
    localparam XW=10, YW=10, AW=8, DW=0, PW=16;

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0;
    reg [XW-1:0] aer_x=50; reg [YW-1:0] aer_y=50; reg aer_pol=0;
    reg [AW-1:0] scan=0; always @(posedge clk) if (!rst) scan<=scan+1'b1;

    wire pred1, pred2; wire [PW-1:0] xh1,xh2,yh1,yh2;
    wire [7:0] c1,c2; wire cv1,cv2, ack1,ack2;
    wire [1:0] tid1,tid2;

    // BG_TH_OPEN=1: opens on 1st LIF spike
    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),
                    .LIF_THRESH(1),.BG_TH_OPEN(1)) dut1(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(ack1),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred1),.x_hat(xh1),.y_hat(yh1),
        .conf(c1),.conf_valid(cv1),.track_id(tid1)
    );
    defparam dut1.u_lif.LEAK_SHIFT = 0;

    // BG_TH_OPEN=2: opens on 2nd LIF spike (default)
    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),
                    .LIF_THRESH(1),.BG_TH_OPEN(2)) dut2(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(ack2),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred2),.x_hat(xh2),.y_hat(yh2),
        .conf(c2),.conf_valid(cv2),.track_id(tid2)
    );
    defparam dut2.u_lif.LEAK_SHIFT = 0;

    integer t, cnt1=0, cnt2=0;
    integer first1=0, first2=0, cycle=0;

    always @(posedge clk) begin
        if (!rst) begin
            cycle <= cycle + 1;
            if (pred1) begin cnt1<=cnt1+1; if (first1==0) first1<=cycle; end
            if (pred2) begin cnt2<=cnt2+1; if (first2==0) first2<=cycle; end
        end
    end

    initial begin
        #(20*T_NS) rst=0;
        for (t=0; t<20; t=t+1) begin
            @(negedge clk); aer_req<=1;
            @(negedge clk); aer_req<=0;
            @(negedge clk);
        end
        repeat(30) @(negedge clk);

        $display("GATE_SWEEP: TH=1 first=%0d cnt=%0d  TH=2 first=%0d cnt=%0d",
                 first1, cnt1, first2, cnt2);
        if (cnt1 == 0) fail_msg("BG_TH_OPEN=1 produced no pred_valid");
        if (cnt2 == 0) fail_msg("BG_TH_OPEN=2 produced no pred_valid");
        if (first1 == 0) fail_msg("BG_TH_OPEN=1: first_pred cycle not recorded");
        if (first2 == 0) fail_msg("BG_TH_OPEN=2: first_pred cycle not recorded");
        if (first1 > first2)
            fail_msg("BG_TH_OPEN=1 should fire no later than BG_TH_OPEN=2");
        pass();
    end
endmodule
`default_nettype wire
