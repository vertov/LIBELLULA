`timescale 1ns/1ps
`default_nettype none

// tb_overflow_flags: AER RX handshake correctness under continuous injection.
// aer_rx is combinational: ack = req within one clock.
// Hold aer_req high for BURST_CYCLES cycles and verify ack mirrors req
// on every posedge (no missed acks, no phantom acks, no hang).

`include "tb_common_tasks.vh"
module tb_overflow_flags;
    localparam T_NS = 5;
    localparam XW=10, YW=10;
    localparam BURST_CYCLES = 100;

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=50; reg [YW-1:0] aer_y=50; reg aer_pol=0;

    wire ev_valid; wire [XW-1:0] ev_x; wire [YW-1:0] ev_y; wire ev_pol;
    aer_rx #(.XW(XW),.YW(YW)) dut(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .ev_valid(ev_valid),.ev_x(ev_x),.ev_y(ev_y),.ev_pol(ev_pol)
    );

    integer ack_count=0, mismatch=0;

    always @(posedge clk) begin
        if (!rst) begin
            // ack must exactly mirror req (combinational pass-through registered)
            if (aer_req && !aer_ack) mismatch <= mismatch + 1;
            if (!aer_req && aer_ack)  mismatch <= mismatch + 1;
            if (aer_ack) ack_count <= ack_count + 1;
        end
    end

    initial begin
        #(10*T_NS) rst=0;
        @(negedge clk);

        // Idle: verify no spurious ack
        repeat(5) @(negedge clk);

        // Burst: hold req high for BURST_CYCLES
        aer_req = 1;
        repeat(BURST_CYCLES) @(posedge clk);
        @(negedge clk);
        aer_req = 0;
        repeat(5) @(negedge clk);

        $display("OVERFLOW: ack_count=%0d mismatch=%0d (expected ack_count=%0d)",
                 ack_count, mismatch, BURST_CYCLES);
        if (mismatch > 0)
            fail_msg("aer_ack did not mirror aer_req during burst");
        if (ack_count < BURST_CYCLES - 2 || ack_count > BURST_CYCLES + 2)
            fail_msg("ack_count mismatch during burst injection");
        pass();
    end
endmodule
`default_nettype wire
