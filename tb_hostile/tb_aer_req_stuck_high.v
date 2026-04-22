`timescale 1ns/1ps
`default_nettype none

// Hostile bench: aer_req held high for multiple cycles.
//
// This is specifically validating the *documented* simplified aer_rx semantics:
// - aer_ack pulses high for one cycle whenever aer_req is high.
// - ev_valid pulses high for one cycle whenever aer_req is high.
// - If aer_req is not deasserted by the source, multiple events will be emitted (duplicate events).
//
// PASS criteria (spec):
// - For N cycles with aer_req=1, we observe N cycles with aer_ack=1 and ev_valid=1.
// - The emitted ev_x/ev_y/ev_pol must equal the held input values.

module tb_aer_req_stuck_high;
    localparam integer T_NS = 5;
    localparam integer XW = 10;
    localparam integer YW = 10;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(T_NS/2) clk = ~clk;

    reg aer_req = 1'b0;
    wire aer_ack;
    reg [XW-1:0] aer_x = {XW{1'b0}};
    reg [YW-1:0] aer_y = {YW{1'b0}};
    reg aer_pol = 1'b0;

    wire ev_valid;
    wire [XW-1:0] ev_x;
    wire [YW-1:0] ev_y;
    wire ev_pol;

    aer_rx #(.XW(XW),.YW(YW)) dut (
        .clk(clk), .rst(rst),
        .aer_req(aer_req), .aer_ack(aer_ack),
        .aer_x(aer_x), .aer_y(aer_y), .aer_pol(aer_pol),
        .ev_valid(ev_valid), .ev_x(ev_x), .ev_y(ev_y), .ev_pol(ev_pol)
    );

    integer i;
    integer errors = 0;
    integer ack_count = 0;
    integer ev_count  = 0;

    initial begin
        $display("=== HOSTILE: tb_aer_req_stuck_high ===");
        repeat (6) @(negedge clk);
        rst = 1'b0;

        // Hold stable address, hold request high for 20 cycles
        aer_x = 10'd123;
        aer_y = 10'd456;
        aer_pol = 1'b1;

        @(negedge clk);
        aer_req = 1'b1;
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk);
            if (aer_ack) ack_count = ack_count + 1;
            if (ev_valid) ev_count = ev_count + 1;
            if (ev_valid) begin
                if (ev_x !== aer_x || ev_y !== aer_y || ev_pol !== aer_pol) begin
                    $display("ERROR: emitted event mismatch at t=%0t ev=(%0d,%0d,%0b)", $time, ev_x, ev_y, ev_pol);
                    errors = errors + 1;
                end
            end
        end
        @(negedge clk);
        aer_req = 1'b0;

        if (ack_count !== 20) begin
            $display("ERROR: expected 20 ack pulses, saw %0d", ack_count);
            errors = errors + 1;
        end
        if (ev_count !== 20) begin
            $display("ERROR: expected 20 ev_valid pulses, saw %0d", ev_count);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS");
        else $display("FAIL: errors=%0d", errors);
        $finish;
    end
endmodule

`default_nettype wire
