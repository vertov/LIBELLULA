`timescale 1ns/1ps
`default_nettype none

// tb_drop_count_accounting: Event throughput and ACK accounting.
// Sends N events with proper req/ack handshake (2 clocks each).
// Asserts: ack_count == N (every sent event is acknowledged, none dropped).
// Also verifies ev_valid tracks ev_count == ack_count.

`include "tb_common_tasks.vh"
module tb_drop_count_accounting;
    localparam T_NS = 5;
    localparam XW=10, YW=10;
    localparam N = 50;

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=0; reg [YW-1:0] aer_y=0; reg aer_pol=0;

    wire ev_valid; wire [XW-1:0] ev_x; wire [YW-1:0] ev_y; wire ev_pol;
    aer_rx #(.XW(XW),.YW(YW)) dut(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .ev_valid(ev_valid),.ev_x(ev_x),.ev_y(ev_y),.ev_pol(ev_pol)
    );

    integer ack_count=0, ev_count=0, t;

    always @(posedge clk) begin
        if (!rst) begin
            if (aer_ack)  ack_count <= ack_count + 1;
            if (ev_valid) ev_count  <= ev_count  + 1;
        end
    end

    initial begin
        #(10*T_NS) rst=0;
        for (t=0; t<N; t=t+1) begin
            @(negedge clk);
            aer_x <= t[XW-1:0]; aer_y <= 0; aer_req <= 1;
            @(negedge clk);
            aer_req <= 0;
            @(negedge clk);
        end
        repeat(5) @(negedge clk);

        $display("DROP_ACCT: sent=%0d ack=%0d ev_valid=%0d", N, ack_count, ev_count);
        if (ack_count != N)
            fail_msg("ack_count != N: events were dropped or phantom acks appeared");
        if (ev_count != N)
            fail_msg("ev_valid count != N: ev_valid not aligned with ack");
        pass();
    end
endmodule
`default_nettype wire
