`timescale 1ns/1ps
`default_nettype none

// Gate-1 regression: demonstrate that a legally stimulated time-multiplexed
// LIF cell reaches threshold under the documented recurrence.
//
// Adapted from CDX tb_lif_liveness for v22:
//   - Spatial tile hash: TARGET_ADDR = {TARGET_X[XW-1:XW-HX], TARGET_Y[YW-1:YW-HY]}
//     (was XOR hash in CDX; v22 lif_tile_tmux uses spatial hash for locality)
//   - P_LEAK_SHIFT default raised to 4 (matches v22 lif_tile_tmux default)
//   - P_EXPECTED_MAX_HIT = 16: with LEAK_SHIFT=4, integer leak rounds to 0 until
//     state reaches 16, so spike occurs after exactly 16 consecutive hits
//   - P_MAX_HITS = 20: guards against infinite spin, with headroom above 16
//   - HIT_WEIGHT removed: v22 lif_tile_tmux always adds 1 per hit (no parameter)
//   - out_ex/out_ey ports connected (open)
module tb_lif_liveness #(
    parameter integer P_LEAK_SHIFT      = 4,
    parameter integer P_THRESH          = 16,
    parameter integer P_MAX_HITS        = 25,
    // 16 accumulations to threshold + 2 pipeline cycles (stage0 latch + out_valid_int
    // registration) = 18 in_valid cycles before out_valid asserts.
    parameter integer P_EXPECTED_MAX_HIT = 18,
    parameter integer P_SCENARIO_ID     = 0,
    parameter bit     P_REQUIRE_SPIKE   = 1
);
    localparam integer T_NS = 5;  // 200 MHz
    localparam integer XW = 10;
    localparam integer YW = 10;
    localparam integer AW = 8;
    localparam integer SW = 14;
    localparam integer HX = AW / 2;
    localparam integer HY = AW - HX;
    localparam [XW-1:0] TARGET_X = 10'd37;
    localparam [YW-1:0] TARGET_Y = 10'd21;
    // Spatial tile hash: top HX bits of x concatenated with top HY bits of y.
    // Must match lif_tile_tmux's hashed_xy computation exactly.
    localparam [AW-1:0] TARGET_ADDR = {TARGET_X[XW-1:XW-HX], TARGET_Y[YW-1:YW-HY]};

    reg clk = 0;
    reg rst = 1;
    always #(T_NS/2) clk = ~clk;

    reg in_valid = 0;
    reg [XW-1:0] in_x = 0;
    reg [YW-1:0] in_y = 0;
    reg in_pol = 0;
    reg [AW-1:0] scan_addr = TARGET_ADDR;

    wire out_valid;

    lif_tile_tmux #(
        .XW(XW), .YW(YW), .AW(AW), .SW(SW),
        .LEAK_SHIFT(P_LEAK_SHIFT),
        .THRESH(P_THRESH)
    ) dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_x(in_x), .in_y(in_y), .in_pol(in_pol),
        .scan_addr(scan_addr),
        .out_valid(out_valid), .out_x(), .out_y(), .out_pol(),
        .out_ex(), .out_ey()
    );

    integer cycle = 0;
    always @(posedge clk) begin
        if (rst)
            cycle <= 0;
        else
            cycle <= cycle + 1;
    end

    integer hits_generated = 0;
    integer hits_to_spike = -1;
    integer spike_cycle = -1;

    always @(posedge clk) begin
        if (rst) begin
            hits_to_spike <= -1;
            spike_cycle <= -1;
        end else if (out_valid && hits_to_spike < 0) begin
            hits_to_spike <= hits_generated;
            spike_cycle <= cycle;
        end
    end

    integer trace_enable = 0;
    integer trace_f = 0;
    reg [1023:0] trace_filename = "build/lif_gate1_trace.csv";
    initial begin
        if ($test$plusargs("GATE1_TRACE") || $test$plusargs("LIF_TRACE")) begin
            if (!$value$plusargs("TRACE_FILE=%s", trace_filename)) begin
                trace_filename = "build/lif_gate1_trace.csv";
            end
            trace_enable = 1;
            trace_f = $fopen(trace_filename, "w");
            if (trace_f) begin
                $display("GATE1_TRACE: logging to %0s", trace_filename);
                $fwrite(trace_f,
                        "scenario_id,cycle,requested_scan,target_addr,event_presented,event_retimed,accum_before,leak_amount,hit_weight,accum_after,writeback,threshold,spike\n");
            end else begin
                $display("WARNING: Unable to open %0s", trace_filename);
            end
        end
    end

    final begin
        if (trace_enable && trace_f)
            $fclose(trace_f);
    end

    always @(posedge clk) begin
        if (trace_enable && trace_f && !rst) begin
            $fwrite(trace_f, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                    P_SCENARIO_ID,
                    cycle,
                    scan_addr,
                    TARGET_ADDR,
                    in_valid,
                    (in_valid && (dut.hashed_xy != scan_addr)),
                    dut.st_read,
                    dut.leak_amount,
                    1,              // hit_weight is always 1 in v22 lif_tile_tmux
                    dut.st_next,
                    dut.st_writeback,
                    dut.THRESH,
                    out_valid);
        end
    end

    initial begin : main
        $display("=== tb_lif_liveness ===");
        $display("Parameters: LEAK_SHIFT=%0d THRESH=%0d (hit_weight=1 in v22)",
                 P_LEAK_SHIFT, P_THRESH);

        repeat (6) @(negedge clk);
        rst = 0;
        @(negedge clk);

        fork
            begin : drive_hits
                while ((hits_generated < P_MAX_HITS) && (hits_to_spike < 0)) begin
                    @(negedge clk);
                    in_valid = 1'b1;
                    in_x = TARGET_X;
                    in_y = TARGET_Y;
                    in_pol = 1'b1;
                    hits_generated = hits_generated + 1;
                end
                in_valid = 1'b0;
            end
            begin : timeout
                repeat (500) @(negedge clk);
                $display("ERROR: Timeout waiting for spike.");
                $finish(1);
            end
        join_any
        disable timeout;

        // Allow remaining pipeline cycles to settle
        repeat (6) @(negedge clk);

        if (hits_to_spike < 0) begin
            if (P_REQUIRE_SPIKE) begin
                $display("ERROR: No spikes observed after %0d hits (max=%0d).",
                         hits_generated, P_MAX_HITS);
                $finish(1);
            end else begin
                $display("INFO: No spike observed after %0d hits (scenario_id=%0d).",
                         hits_generated, P_SCENARIO_ID);
                $finish(0);
            end
        end

        $display("Spike observed after %0d hits at cycle %0d.",
                 hits_to_spike, spike_cycle);

        if (hits_to_spike > P_EXPECTED_MAX_HIT) begin
            $display("ERROR: Spike required %0d hits (expected <= %0d).",
                     hits_to_spike, P_EXPECTED_MAX_HIT);
            $finish(1);
        end

        $display("PASS: Gate-1 liveness satisfied.");
        $finish(0);
    end
endmodule

`default_nettype wire
