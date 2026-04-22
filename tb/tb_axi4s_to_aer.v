// =============================================================================
// tb_axi4s_to_aer.v
// Testbench for axi4s_to_aer.v  —  LIBELLULA Core v22
//
// Test plan (7 cases):
//   1. IDLE         : no s_axis_tvalid; verify aer_req stays low for 10 cycles
//   2. BASIC        : single beat, observe 1-cycle aer_req pulse with correct
//                     x / y / pol fields
//   3. PULSE_WIDTH  : aer_req must be high for exactly one clock cycle per beat
//   4. TDATA_UNPACK : verify each TDATA field decodes independently
//   5. BACKPRESS    : s_axis_tready must deassert while FSM is in S_REQ, then
//                     reassert the following cycle
//   6. BURST        : 8 consecutive beats, every event on the AER bus must
//                     carry the expected x / y / pol
//   7. PROTOCOL     : aer_req never high > 1 cycle; tready stable invariants
//
// Compile & run:
//   iverilog -g2012 -DSIMULATION \
//       -o tb_axi4s_to_aer \
//       axi4s_to_aer.v tb_axi4s_to_aer.v
//   vvp tb_axi4s_to_aer
// =============================================================================

`timescale 1ns/1ps

module tb_axi4s_to_aer;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam XW      = 10;
    localparam YW      = 10;
    localparam DATA_W  = 32;
    localparam CLK_PER = 5.0;  // 200 MHz -> 5 ns period

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    reg                     clk;
    reg                     rst_n;

    reg                     s_axis_tvalid;
    wire                    s_axis_tready;
    reg  [DATA_W-1:0]       s_axis_tdata;
    reg  [(DATA_W/8)-1:0]   s_axis_tkeep;
    reg                     s_axis_tlast;

    wire                    aer_req;
    reg                     aer_ack;
    wire [XW-1:0]           aer_x;
    wire [YW-1:0]           aer_y;
    wire                    aer_pol;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    axi4s_to_aer #(
        .XW     (XW),
        .YW     (YW),
        .DATA_W (DATA_W)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tkeep  (s_axis_tkeep),
        .s_axis_tlast  (s_axis_tlast),
        .aer_req       (aer_req),
        .aer_ack       (aer_ack),
        .aer_x         (aer_x),
        .aer_y         (aer_y),
        .aer_pol       (aer_pol)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 1'b0;
    always #(CLK_PER / 2.0) clk = ~clk;

    // Combinationally model LIBELLULA's aer_rx: ack = req while not in reset
    always @(*) aer_ack = aer_req && rst_n;

    // -------------------------------------------------------------------------
    // Pass / fail counters
    // -------------------------------------------------------------------------
    integer pass_count;
    integer fail_count;

    task check;
        input [511:0] label;
        input         ok;
        begin
            if (ok) begin
                $display("  PASS : %0s", label);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL : %0s  (time=%0t)", label, $time);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // pack_beat : build a DATA_W-wide TDATA word from x / y / pol
    // -------------------------------------------------------------------------
    function [DATA_W-1:0] pack_beat;
        input [XW-1:0] xv;
        input [YW-1:0] yv;
        input          pv;
        reg   [DATA_W-1:0] w;
        begin
            w = {DATA_W{1'b0}};
            w[XW-1:0]          = xv;
            w[XW+YW-1:XW]      = yv;
            w[XW+YW]           = pv;
            pack_beat = w;
        end
    endfunction

    // -------------------------------------------------------------------------
    // drive_beat
    // Aligns to negedge, waits until tready=1, drives one AXI4-S beat, then
    // waits for the posedge that fires the handshake.  Returns after that
    // posedge + #1 so aer_req is already the registered value (=1) and
    // aer_x / aer_y / aer_pol carry the latched fields.
    // -------------------------------------------------------------------------
    task drive_beat;
        input [XW-1:0] xv;
        input [YW-1:0] yv;
        input          pv;
        begin
            @(negedge clk);
            while (!s_axis_tready) @(negedge clk);
            s_axis_tdata  = pack_beat(xv, yv, pv);
            s_axis_tkeep  = {(DATA_W/8){1'b1}};
            s_axis_tlast  = 1'b1;
            s_axis_tvalid = 1'b1;
            @(posedge clk); #1;
            s_axis_tvalid = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // do_reset
    // -------------------------------------------------------------------------
    task do_reset;
        begin
            rst_n         = 1'b0;
            s_axis_tvalid = 1'b0;
            s_axis_tdata  = {DATA_W{1'b0}};
            s_axis_tkeep  = {(DATA_W/8){1'b1}};
            s_axis_tlast  = 1'b0;
            repeat(4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    // -------------------------------------------------------------------------
    // Main
    // -------------------------------------------------------------------------
    integer      i;
    reg [XW-1:0] burst_x [0:7];
    reg [YW-1:0] burst_y [0:7];
    reg          burst_p [0:7];

    initial begin
        pass_count = 0;
        fail_count = 0;
        $display("=== tb_axi4s_to_aer : AXI4-Stream -> AER Input Bridge ===");

        // =====================================================================
        // TEST 1 : IDLE
        // =====================================================================
        $display("\n[1] IDLE -- aer_req must stay low with no stimulus");
        do_reset;
        begin : idle_blk
            integer req_seen;
            req_seen = 0;
            repeat(10) begin
                @(posedge clk); #1;
                if (aer_req !== 1'b0) req_seen = req_seen + 1;
            end
            check("aer_req low for 10 idle cycles",  req_seen === 0);
            check("s_axis_tready high when idle",    s_axis_tready === 1'b1);
        end

        // =====================================================================
        // TEST 2 : BASIC single beat
        // =====================================================================
        $display("\n[2] BASIC single beat");
        do_reset;
        drive_beat(10'h123, 10'h1A5, 1'b1);
        check("aer_req asserted",         aer_req === 1'b1);
        check("aer_x  == 0x123",          aer_x   === 10'h123);
        check("aer_y  == 0x1A5",          aer_y   === 10'h1A5);
        check("aer_pol == 1",             aer_pol === 1'b1);
        check("ack modeled (= req)",      aer_ack === 1'b1);
        check("tready low during S_REQ",  s_axis_tready === 1'b0);
        // Next cycle: aer_req must drop, ready must rise again
        @(posedge clk); #1;
        check("aer_req drops next cycle", aer_req === 1'b0);
        check("tready high again",        s_axis_tready === 1'b1);

        // =====================================================================
        // TEST 3 : PULSE WIDTH -- aer_req high for exactly one clock cycle
        // =====================================================================
        $display("\n[3] PULSE WIDTH -- aer_req high for exactly 1 cycle");
        do_reset;
        begin : pulse_blk
            integer high_cycles;
            high_cycles = 0;
            drive_beat(10'h0AA, 10'h055, 1'b0);
            // drive_beat returns with aer_req=1 (first high cycle)
            if (aer_req === 1'b1) high_cycles = high_cycles + 1;
            // Sample for 5 more cycles and count req-high cycles
            repeat(5) begin
                @(posedge clk); #1;
                if (aer_req === 1'b1) high_cycles = high_cycles + 1;
            end
            check("aer_req high for exactly 1 cycle", high_cycles === 1);
        end

        // =====================================================================
        // TEST 4 : TDATA field unpacking
        // =====================================================================
        $display("\n[4] TDATA field unpacking");
        do_reset;
        // Distinctive per-field values
        drive_beat(10'h2AA, 10'h155, 1'b1);
        check("x  [ 9: 0] = 0x2AA",  aer_x   === 10'h2AA);
        check("y  [19:10] = 0x155",  aer_y   === 10'h155);
        check("pol [20]    = 1",     aer_pol === 1'b1);
        @(posedge clk); #1;

        do_reset;
        drive_beat(10'h155, 10'h2AA, 1'b0);
        check("x  flipped = 0x155",  aer_x   === 10'h155);
        check("y  flipped = 0x2AA",  aer_y   === 10'h2AA);
        check("pol flipped = 0",     aer_pol === 1'b0);
        @(posedge clk); #1;

        // =====================================================================
        // TEST 5 : BACKPRESSURE -- upstream tvalid held through a REQ cycle
        // The wrapper should lower tready for exactly 1 cycle, then accept.
        // =====================================================================
        $display("\n[5] BACKPRESSURE");
        do_reset;
        drive_beat(10'h001, 10'h002, 1'b1);
        // Now in S_REQ: tready must be low, tvalid may be high from upstream
        @(negedge clk);
        s_axis_tdata  = pack_beat(10'h003, 10'h004, 1'b0);
        s_axis_tvalid = 1'b1;
        // At the next posedge we are still in S_REQ (the second one since entering)
        // Wait, drive_beat already consumed one posedge inside S_REQ.  So we should
        // already be transitioning to S_IDLE on the next posedge.  Verify that:
        check("tready low during S_REQ",  s_axis_tready === 1'b0);
        @(posedge clk); #1;
        check("tready high after S_REQ", s_axis_tready === 1'b1);
        // Now the second beat should be accepted on the following posedge
        @(posedge clk); #1;
        check("second beat x captured",  aer_x   === 10'h003);
        check("second beat y captured",  aer_y   === 10'h004);
        check("second beat pol captured",aer_pol === 1'b0);
        check("second aer_req pulse",    aer_req === 1'b1);
        s_axis_tvalid = 1'b0;
        @(posedge clk); #1;

        // =====================================================================
        // TEST 6 : BURST 8 consecutive beats
        // =====================================================================
        $display("\n[6] BURST 8 consecutive beats");
        do_reset;
        for (i = 0; i < 8; i = i + 1) begin
            drive_beat(i[XW-1:0] + 10'h010,
                       i[YW-1:0] + 10'h020,
                       i[0]);
            burst_x[i] = aer_x;
            burst_y[i] = aer_y;
            burst_p[i] = aer_pol;
            // Advance past the S_REQ cycle
            @(posedge clk); #1;
        end
        for (i = 0; i < 8; i = i + 1) begin
            check("burst x correct", burst_x[i] === (i[XW-1:0] + 10'h010));
            check("burst y correct", burst_y[i] === (i[YW-1:0] + 10'h020));
            check("burst pol correct", burst_p[i] === i[0]);
        end

        // =====================================================================
        // TEST 7 : PROTOCOL -- long stream, verify invariants throughout
        // =====================================================================
        $display("\n[7] PROTOCOL -- long stream invariants");
        do_reset;
        begin : proto_blk
            integer bad_req;
            integer bad_tready;
            reg     req_d;
            bad_req    = 0;
            bad_tready = 0;
            req_d      = 1'b0;
            // Free-run 60 cycles while continuously trying to push beats
            @(negedge clk);
            s_axis_tvalid = 1'b1;
            s_axis_tdata  = pack_beat(10'h0FF, 10'h0AA, 1'b1);
            repeat(60) begin
                @(posedge clk); #1;
                // Invariant A: aer_req never high two cycles in a row
                if (req_d && aer_req) bad_req = bad_req + 1;
                req_d = aer_req;
                // Invariant B: when aer_req=1, tready must be 0 that cycle
                if (aer_req && s_axis_tready) bad_tready = bad_tready + 1;
            end
            s_axis_tvalid = 1'b0;
            check("aer_req never high > 1 cycle",  bad_req    === 0);
            check("tready low whenever aer_req=1", bad_tready === 0);
        end

        // =====================================================================
        // Summary
        // =====================================================================
        $display("\n=== RESULT : %0d PASS  %0d FAIL ===", pass_count, fail_count);
        if (fail_count === 0)
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Watchdog
    // -------------------------------------------------------------------------
    initial begin
        #500000;
        $display("WATCHDOG TIMEOUT");
        $finish;
    end

endmodule
