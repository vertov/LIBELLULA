`timescale 1ns/1ps
`default_nettype none

// Full-coverage stimulus bench for LIBELLULA Core v22.
//
// Exercises all major RTL paths and dumps a VCD for post-simulation
// toggle / FSM coverage analysis via tools/coverage_report.py.
//
// Scenarios covered:
//   1. Linear rightward motion (pol=1)
//   2. Linear motion with pol=0 (polarity path)
//   3. Mid-stream reset + recovery (reset-state path)
//   4. Post-reset motion with identical stimulus (determinism path)
//   5. Simultaneous target + clutter (different tile) (burst-gate path)
//   6. Dense same-pixel burst (LIF saturation path)
//   7. Idle period (no events — zero-activity path)

`include "tb_common_tasks.vh"
module tb_coverage_full;
    localparam T_NS = 5;
    localparam XW = 10, YW = 10, AW = 8, DW = 0, PW = 16;

    reg clk = 1'b0, rst = 1'b1;
    always #(T_NS/2) clk = ~clk;

    reg aer_req = 1'b0; wire aer_ack;
    reg [XW-1:0] aer_x = {XW{1'b0}};
    reg [YW-1:0] aer_y = {YW{1'b0}};
    reg aer_pol = 1'b0;
    reg [AW-1:0] scan = {AW{1'b0}};
    always @(posedge clk) if (!rst) scan <= scan + 1'b1;

    wire pred_valid; wire [PW-1:0] x_hat, y_hat; wire [7:0] conf; wire conf_valid;
    wire [1:0] tid_unused;

    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),.LIF_THRESH(4)) dut (
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid),.x_hat(x_hat),.y_hat(y_hat),
        .conf(conf),.conf_valid(conf_valid),.track_id(tid_unused)
    );

    task send_event;
        input [XW-1:0] x; input [YW-1:0] y; input pol;
        begin
            @(negedge clk); aer_x=x; aer_y=y; aer_pol=pol; aer_req=1'b1;
            @(negedge clk); aer_req=1'b0;
        end
    endtask

    integer t, pred_cnt = 0;
    always @(posedge clk) if (!rst && pred_valid) pred_cnt <= pred_cnt + 1;

    initial begin
        $dumpfile("build/coverage.vcd");
        $dumpvars(0, dut);

        repeat (20) @(negedge clk);
        rst = 1'b0;

        // 1. Linear rightward, pol=1
        for (t=0; t<40; t=t+1) send_event(10+t, 200, 1'b1);
        repeat (10) @(negedge clk);

        // 2. Linear leftward, pol=0 (polarity complement path)
        for (t=0; t<20; t=t+1) send_event(200-t, 300, 1'b0);
        repeat (10) @(negedge clk);

        // 3. Mid-stream reset
        @(negedge clk); rst = 1'b1;
        repeat ((1<<AW) + 10) @(negedge clk);
        rst = 1'b0;
        repeat (5) @(negedge clk);

        // 4. Post-reset identical stimulus (reset-determinism path)
        for (t=0; t<40; t=t+1) send_event(10+t, 200, 1'b1);
        repeat (10) @(negedge clk);

        // 5. Target + orthogonal-tile clutter interleaved (burst-gate hysteresis path)
        for (t=0; t<20; t=t+1) begin
            send_event(50+t, 200, 1'b1);        // target tile (0,3)
            send_event(500+t[9:0], 600, 1'b0);  // clutter tile (7,9) — independent tile
        end
        repeat (10) @(negedge clk);

        // 6. Dense same-pixel burst (LIF saturation: spike→reset→re-charge path)
        for (t=0; t<30; t=t+1) send_event(100, 100, t[0]);
        repeat (10) @(negedge clk);

        // 7. Idle (no events — zero-activity, leak path)
        repeat (100) @(negedge clk);

        $dumpoff;
        $display("COVERAGE_FULL: pred_cnt=%0d  VCD written to build/coverage.vcd", pred_cnt);
        if (pred_cnt == 0) begin
            fail_msg("no pred_valid outputs produced — coverage stimulus insufficient");
        end
        pass();
    end
endmodule

`default_nettype wire
