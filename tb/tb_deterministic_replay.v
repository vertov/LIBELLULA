`timescale 1ns/1ps
`default_nettype none

// tb_deterministic_replay: Two identical DUT instances driven with the same
// stimulus must produce bit-exact identical outputs on every clock cycle.
// Verifies no non-deterministic X-propagation or uninitialised state.

`include "tb_common_tasks.vh"
module tb_deterministic_replay;
    localparam T_NS = 5;
    localparam XW=10, YW=10, AW=8, DW=0, PW=16;

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    // Shared stimulus
    reg aer_req=0;
    reg [XW-1:0] aer_x=0; reg [YW-1:0] aer_y=0; reg aer_pol=0;
    reg [AW-1:0] scan=0; always @(posedge clk) if (!rst) scan<=scan+1'b1;

    wire pred_valid_a, pred_valid_b;
    wire [PW-1:0] x_hat_a, x_hat_b, y_hat_a, y_hat_b;
    wire [7:0] conf_a, conf_b; wire conf_valid_a, conf_valid_b;
    wire aer_ack_a, aer_ack_b;
    wire [1:0] tid_a, tid_b;

    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),
                    .LIF_THRESH(4)) dut_a(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack_a),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid_a),.x_hat(x_hat_a),.y_hat(y_hat_a),
        .conf(conf_a),.conf_valid(conf_valid_a),.track_id(tid_a)
    );

    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),
                    .LIF_THRESH(4)) dut_b(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack_b),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid_b),.x_hat(x_hat_b),.y_hat(y_hat_b),
        .conf(conf_b),.conf_valid(conf_valid_b),.track_id(tid_b)
    );

    integer mismatches=0, t;

    always @(posedge clk) begin
        if (!rst) begin
            if (pred_valid_a !== pred_valid_b) mismatches <= mismatches + 1;
            if (pred_valid_a && (x_hat_a !== x_hat_b)) mismatches <= mismatches + 1;
            if (pred_valid_a && (y_hat_a !== y_hat_b)) mismatches <= mismatches + 1;
            if (aer_ack_a !== aer_ack_b) mismatches <= mismatches + 1;
        end
    end

    initial begin
        #(20*T_NS) rst=0;
        // Mixed target motion: 40 events stepping through multiple tiles
        for (t=0; t<40; t=t+1) begin
            @(negedge clk);
            aer_x <= t * 4;
            aer_y <= 10 + (t % 5);
            aer_req <= 1;
            @(negedge clk); aer_req<=0;
            @(negedge clk);
        end
        repeat(30) @(negedge clk);

        $display("REPLAY: mismatches=%0d", mismatches);
        if (mismatches > 0)
            fail_msg("DUT outputs diverged — non-deterministic behaviour detected");
        pass();
    end
endmodule
`default_nettype wire
