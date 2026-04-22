`timescale 1ns/1ps
`default_nettype none

// tb_target_stop_start: Target moves, stops (no events), then resumes.
// Phase 1: 20 events → LIF fires, burst gate opens, pred_valid fires.
// Gap:     300 idle cycles (no events).
// Phase 2: 20 events at a new position → pred_valid fires again.
// Asserts: pred_valid fires in both phases.

`include "tb_common_tasks.vh"
module tb_target_stop_start;
    localparam T_NS = 5;
    localparam XW=10, YW=10, AW=8, DW=0, PW=16;

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=50; reg [YW-1:0] aer_y=50; reg aer_pol=0;
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

    integer t, pred_ph1=0, pred_ph2=0;
    integer phase=0;

    always @(posedge clk) begin
        if (pred_valid) begin
            if (phase == 1) pred_ph1 <= pred_ph1 + 1;
            if (phase == 2) pred_ph2 <= pred_ph2 + 1;
        end
    end

    initial begin
        #(20*T_NS) rst=0;

        // ---- Phase 1: 20 events at x=50..69, y=50 ----
        phase = 1;
        for (t=0; t<20; t=t+1) begin
            @(negedge clk);
            aer_x <= 50 + t; aer_req<=1;
            @(negedge clk); aer_req<=0;
            @(negedge clk);
        end
        repeat(20) @(negedge clk);

        // ---- Gap: 300 idle cycles ----
        phase = 0;
        repeat(300) @(negedge clk);

        // ---- Phase 2: 20 events at x=200..219, y=50 ----
        phase = 2;
        aer_x <= 200; aer_y <= 50;
        for (t=0; t<20; t=t+1) begin
            @(negedge clk);
            aer_x <= 200 + t; aer_req<=1;
            @(negedge clk); aer_req<=0;
            @(negedge clk);
        end
        repeat(20) @(negedge clk);

        $display("STOPSTART: phase1_preds=%0d  phase2_preds=%0d",
                 pred_ph1, pred_ph2);
        if (pred_ph1 == 0)
            fail_msg("pred_valid did not fire in phase 1");
        if (pred_ph2 == 0)
            fail_msg("pred_valid did not fire in phase 2 (re-acquire failed)");
        pass();
    end
endmodule
`default_nettype wire
