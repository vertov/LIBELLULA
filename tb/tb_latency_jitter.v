`timescale 1ns/1ps
`default_nettype none

// tb_latency_jitter: Pipeline latency consistency across successive events.
// Sends 5 events after the burst gate is open and measures cycle-count from
// aer_req assertion to pred_valid.  The pipeline is fully synchronous with no
// random elements, so all latencies must be identical (max - min == 0).
// Allowed tolerance: ±1 cycle to account for negedge/posedge measurement skew.

`include "tb_common_tasks.vh"
module tb_latency_jitter;
    localparam T_NS = 5;
    localparam XW=10, YW=10, AW=8, DW=0, PW=16;
    localparam MEAS_N = 5;

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=12; reg [YW-1:0] aer_y=21; reg aer_pol=0;
    reg [AW-1:0] scan=0; always @(posedge clk) if (!rst) scan<=scan+1'b1;

    wire pred_valid; wire [PW-1:0] x_hat,y_hat; wire [7:0] conf; wire conf_valid;
    wire [1:0] tid_unused;

    // Use THRESH=1 and BG_TH_OPEN=1 so each event produces pred_valid,
    // making latency measurement straightforward.
    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),
                    .LIF_THRESH(1),.BG_TH_OPEN(1)) dut(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid),.x_hat(x_hat),.y_hat(y_hat),
        .conf(conf),.conf_valid(conf_valid),.track_id(tid_unused)
    );

    // LEAK_SHIFT=0 so state doesn't drop below THRESH=1 between events
    defparam dut.u_lif.LEAK_SHIFT = 0;

    integer lat [0:MEAS_N-1];
    integer meas_i, cyc, lat_min, lat_max, jitter;

    task measure_one;
        output integer latency;
        integer c;
        reg timed_out;
        begin
            c = 0; timed_out = 0;
            @(negedge clk); aer_req <= 1;
            @(negedge clk); aer_req <= 0;
            fork
                begin
                    while (!pred_valid) begin
                        @(posedge clk); c = c + 1;
                        if (c > 50) begin timed_out = 1; disable fork; end
                    end
                end
                begin repeat(60) @(posedge clk); end
            join_any
            disable fork;
            if (timed_out || !pred_valid) begin
                $display("JITTER: TIMEOUT waiting for pred_valid"); latency = 99;
            end else begin
                latency = c;
            end
            // Drain: wait for pipeline to quiesce
            repeat(15) @(negedge clk);
        end
    endtask

    initial begin
        #(20*T_NS) rst=0;

        // Warm up: open burst gate (send 2 events, discard latencies)
        repeat(2) begin
            @(negedge clk); aer_req<=1;
            @(negedge clk); aer_req<=0;
            repeat(15) @(negedge clk);
        end

        // Measure MEAS_N latencies
        for (meas_i=0; meas_i<MEAS_N; meas_i=meas_i+1) begin
            measure_one(lat[meas_i]);
            $display("JITTER: meas[%0d] = %0d cycles", meas_i, lat[meas_i]);
        end

        // Compute jitter
        lat_min = lat[0]; lat_max = lat[0];
        for (meas_i=1; meas_i<MEAS_N; meas_i=meas_i+1) begin
            if (lat[meas_i] < lat_min) lat_min = lat[meas_i];
            if (lat[meas_i] > lat_max) lat_max = lat[meas_i];
        end
        jitter = lat_max - lat_min;
        $display("JITTER: min=%0d max=%0d jitter=%0d cycles", lat_min, lat_max, jitter);

        if (lat_max >= 99) fail_msg("Latency measurement timed out");
        if (jitter > 1)    fail_msg("Latency jitter >1 cycle in deterministic pipeline");
        pass();
    end
endmodule
`default_nettype wire
