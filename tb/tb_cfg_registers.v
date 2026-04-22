`timescale 1ns/1ps
`default_nettype none

// tb_cfg_registers: Verify LIF_THRESH and BG_TH_OPEN top-level parameters
// actually change pipeline behaviour.
//
// Two DUT instances run the same 10-event stimulus:
//   dut_lo: LIF_THRESH=4  → 2 LIF spikes → burst gate opens → pred_valid fires
//   dut_hi: LIF_THRESH=8  → 1 LIF spike  → burst gate stays shut → pred_valid stays 0

`include "tb_common_tasks.vh"
module tb_cfg_registers;
    localparam T_NS = 5;
    localparam XW=10, YW=10, AW=8, DW=0, PW=16;

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0;
    reg [XW-1:0] aer_x=100; reg [YW-1:0] aer_y=100; reg aer_pol=0;
    reg [AW-1:0] scan=0; always @(posedge clk) if (!rst) scan<=scan+1'b1;

    wire aer_ack_lo, aer_ack_hi;
    wire pred_valid_lo; wire [PW-1:0] x_hat_lo, y_hat_lo;
    wire pred_valid_hi; wire [PW-1:0] x_hat_hi, y_hat_hi;
    wire [7:0] conf_lo, conf_hi; wire conf_valid_lo, conf_valid_hi;
    wire [1:0] tid_lo, tid_hi;

    // Low threshold: fires twice in 10 events → gate opens → pred_valid asserts
    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),
                    .LIF_THRESH(4)) dut_lo (
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack_lo),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid_lo),.x_hat(x_hat_lo),.y_hat(y_hat_lo),
        .conf(conf_lo),.conf_valid(conf_valid_lo),.track_id(tid_lo)
    );

    // High threshold: fires once in 10 events → gate stays shut → pred_valid=0
    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),
                    .LIF_THRESH(8)) dut_hi (
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack_hi),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid_hi),.x_hat(x_hat_hi),.y_hat(y_hat_hi),
        .conf(conf_hi),.conf_valid(conf_valid_hi),.track_id(tid_hi)
    );

    integer cnt_lo=0, cnt_hi=0, t;

    always @(posedge clk) begin
        if (pred_valid_lo) cnt_lo <= cnt_lo + 1;
        if (pred_valid_hi) cnt_hi <= cnt_hi + 1;
    end

    initial begin
        #(20*T_NS) rst=0;
        for (t=0; t<10; t=t+1) begin
            @(negedge clk); aer_req<=1;
            @(negedge clk); aer_req<=0;
            @(negedge clk);
        end
        repeat(20) @(negedge clk);

        $display("CFG_REG: THRESH=4 pred_count=%0d  THRESH=8 pred_count=%0d",
                 cnt_lo, cnt_hi);

        if (cnt_lo == 0)
            fail_msg("LIF_THRESH=4 should produce pred_valid in 10 events");
        if (cnt_hi != 0)
            fail_msg("LIF_THRESH=8 should NOT produce pred_valid in 10 events");
        pass();
    end
endmodule
`default_nettype wire
