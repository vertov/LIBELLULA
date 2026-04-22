`timescale 1ns/1ps
`default_nettype none

// tb_occlusion_reacquire: Target visible → gap (occlusion) → visible again.
// With LIF_THRESH=4 and DW=0: 20 events per phase produce ~5 LIF spikes each.
// Burst gate opens at spike 2 and stays open (no window reset).
// Phase 1: pred_valid fires during the first visible period.
// Phase 2: pred_valid fires again after the 200-cycle gap (re-acquisition).

`include "tb_common_tasks.vh"
module tb_occlusion_reacquire;
    localparam T_NS = 5;
    localparam XW=10, YW=10, AW=8, DW=0, PW=16;

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=100; reg [YW-1:0] aer_y=100; reg aer_pol=0;
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

    integer t, pred_ph1=0, pred_ph2=0, phase=0;

    always @(posedge clk) begin
        if (pred_valid) begin
            if (phase == 1) pred_ph1 <= pred_ph1 + 1;
            if (phase == 2) pred_ph2 <= pred_ph2 + 1;
        end
    end

    initial begin
        #(20*T_NS) rst=0;

        // Phase 1: visible
        phase = 1;
        for (t=0; t<20; t=t+1) begin
            @(negedge clk); aer_x<=100+t; aer_req<=1;
            @(negedge clk); aer_req<=0;
            @(negedge clk);
        end
        repeat(10) @(negedge clk);

        // Occlusion: 200 idle cycles
        phase = 0;
        repeat(200) @(negedge clk);

        // Phase 2: visible again (shifted position)
        phase = 2;
        for (t=0; t<20; t=t+1) begin
            @(negedge clk); aer_x<=120+t; aer_req<=1;
            @(negedge clk); aer_req<=0;
            @(negedge clk);
        end
        repeat(10) @(negedge clk);

        $display("OCCLUSION: phase1_preds=%0d  phase2_preds=%0d",
                 pred_ph1, pred_ph2);
        if (pred_ph1 == 0)
            fail_msg("pred_valid did not fire in phase 1 (pre-occlusion)");
        if (pred_ph2 == 0)
            fail_msg("pred_valid did not fire in phase 2 (re-acquisition after gap)");
        pass();
    end
endmodule
`default_nettype wire
