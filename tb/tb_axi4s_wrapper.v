// =============================================================================
// tb_axi4s_wrapper.v
// Testbench for axi4s_pred_wrapper.v  —  LIBELLULA Core v22
//
// Test plan (7 cases):
//   1. IDLE         : no pred_valid; verify TVALID stays low for 10 cycles
//   2. BASIC        : single pred_valid; consumer ready immediately
//   3. BACKPRESSURE : consumer holds TREADY low for 5 cycles; TVALID must
//                     stay asserted until TREADY rises
//   4. TDATA_PACK   : verify all four bit-fields individually
//   5. TLAST        : TLAST === TVALID across 20 cycles (active + idle)
//   6. BURST        : 8 consecutive predictions, consumer always ready;
//                     every beat must have correct x/y/conf
//   7. PROTOCOL     : TVALID never deasserts mid-stall (AXI4-S compliance)
//
// Timing note
// -----------
// drive_pred() exits after the posedge where pred_valid=1 is captured
// (plus a #1 guard). At that instant the registered output m_axis_tvalid
// is already 1. Tests therefore sample outputs IMMEDIATELY after
// drive_pred() returns, before advancing another clock edge.
//
// Compile & run:
//   iverilog -g2012 -DSIMULATION \
//       -o tb_axi4s_wrapper \
//       ../rtl/axi4s_pred_wrapper.v tb_axi4s_wrapper.v
//   vvp tb_axi4s_wrapper
// =============================================================================

`timescale 1ns/1ps

module tb_axi4s_wrapper;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam PW      = 16;
    localparam CONFW   =  8;
    localparam CLK_PER = 5.0;  // 200 MHz -> 5 ns period

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    reg              clk;
    reg              rst_n;
    reg              pred_valid;
    reg  [PW-1:0]    x_pred;
    reg  [PW-1:0]    y_pred;
    reg  [CONFW-1:0] conf;
    wire             m_axis_tvalid;
    reg              m_axis_tready;
    wire [47:0]      m_axis_tdata;
    wire [5:0]       m_axis_tkeep;
    wire             m_axis_tlast;

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    axi4s_pred_wrapper #(
        .PW   (PW),
        .CONFW(CONFW)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .pred_valid    (pred_valid),
        .x_pred        (x_pred),
        .y_pred        (y_pred),
        .conf          (conf),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tkeep  (m_axis_tkeep),
        .m_axis_tlast  (m_axis_tlast)
    );

    // -------------------------------------------------------------------------
    // Clock
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #(CLK_PER / 2.0) clk = ~clk;

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
                $display("  PASS : %s", label);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL : %s  (time=%0t)", label, $time);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // drive_pred
    // Asserts pred_valid for exactly one rising clock edge, then deasserts.
    // Returns after posedge + #1, so m_axis_tvalid is already registered
    // when the caller resumes.
    // -------------------------------------------------------------------------
    task drive_pred;
        input [PW-1:0]    xv;
        input [PW-1:0]    yv;
        input [CONFW-1:0] cv;
        begin
            @(negedge clk);
            x_pred     = xv;
            y_pred     = yv;
            conf       = cv;
            pred_valid = 1'b1;
            @(posedge clk);
            #1;
            pred_valid = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // do_reset
    // -------------------------------------------------------------------------
    task do_reset;
        begin
            rst_n         = 1'b0;
            pred_valid    = 1'b0;
            x_pred        = 0;
            y_pred        = 0;
            conf          = 0;
            m_axis_tready = 1'b1;
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
    reg [47:0]   burst_data [0:7];
    reg [47:0]   expected;

    initial begin
        pass_count = 0;
        fail_count = 0;
        $display("=== tb_axi4s_wrapper : AXI4-Stream Output Wrapper ===");

        // =====================================================================
        // TEST 1 : IDLE
        // =====================================================================
        $display("\n[1] IDLE -- TVALID must stay low with no stimulus");
        do_reset;
        m_axis_tready = 1'b1;
        repeat(10) @(posedge clk); #1;
        check("TVALID low during idle", m_axis_tvalid === 1'b0);

        // =====================================================================
        // TEST 2 : BASIC single beat, consumer always ready
        // Sample immediately after drive_pred (TVALID already registered=1).
        // =====================================================================
        $display("\n[2] BASIC single beat, consumer ready");
        do_reset;
        m_axis_tready = 1'b1;
        drive_pred(16'h0A80, 16'h0640, 8'hBE);
        // m_axis_tvalid is 1 here (registered at the posedge inside drive_pred)
        check("TVALID asserted",             m_axis_tvalid === 1'b1);
        expected = {8'd0, 8'hBE, 16'h0640, 16'h0A80};
        check("TDATA correct",               m_axis_tdata  === expected);
        check("TLAST == TVALID (=1)",        m_axis_tlast  === 1'b1);
        check("TKEEP all bytes valid",       m_axis_tkeep  === 6'b111111);
        // Advance: TREADY=1 so handshake fires and TVALID clears
        @(posedge clk); #1;
        check("TVALID deasserts after handshake", m_axis_tvalid === 1'b0);
        check("TLAST == TVALID (=0)",             m_axis_tlast  === 1'b0);

        // =====================================================================
        // TEST 3 : BACKPRESSURE
        // =====================================================================
        $display("\n[3] BACKPRESSURE -- consumer stalls 5 cycles");
        do_reset;
        m_axis_tready = 1'b0;
        drive_pred(16'h1234, 16'h5678, 8'hAA);
        check("TVALID asserted under backpressure", m_axis_tvalid === 1'b1);
        // Hold stall for 4 more posedges
        repeat(4) begin
            @(posedge clk); #1;
            check("TVALID held during stall", m_axis_tvalid === 1'b1);
        end
        // Release TREADY; the next posedge fires the handshake.
        // Sampling at posedge+#1 sees the post-handshake registered value (=0).
        @(negedge clk); m_axis_tready = 1'b1;
        @(posedge clk); #1;
        check("TVALID deasserts immediately after transfer", m_axis_tvalid === 1'b0);

        // =====================================================================
        // TEST 4 : TDATA field packing
        // =====================================================================
        $display("\n[4] TDATA field packing");
        do_reset;
        m_axis_tready = 1'b1;
        // Distinctive per-field values
        drive_pred(16'h00FF, 16'hFF00, 8'hC3);
        check("x_pred  [15:0]  = 0x00FF",  m_axis_tdata[15: 0] === 16'h00FF);
        check("y_pred  [31:16] = 0xFF00",  m_axis_tdata[31:16] === 16'hFF00);
        check("conf    [39:32] = 0xC3",    m_axis_tdata[39:32] === 8'hC3);
        check("padding [47:40] = 0x00",    m_axis_tdata[47:40] === 8'h00);
        @(posedge clk); #1;

        // =====================================================================
        // TEST 5 : TLAST === TVALID for 20 consecutive cycles
        // =====================================================================
        $display("\n[5] TLAST == TVALID invariant (20 cycles)");
        do_reset;
        m_axis_tready = 1'b1;
        begin : tlast_blk
            integer mismatch;
            mismatch = 0;
            drive_pred(16'h0100, 16'h0200, 8'h10);
            // Start checking right now (before any clock advance)
            repeat(20) begin
                if (m_axis_tlast !== m_axis_tvalid) mismatch = mismatch + 1;
                @(posedge clk); #1;
            end
            check("TLAST === TVALID for 20 cycles", mismatch === 0);
        end

        // =====================================================================
        // TEST 6 : BURST 8 consecutive predictions, consumer always ready
        // Capture TDATA immediately after each drive_pred (TVALID=1, settled).
        // Then advance one clock to complete that beat's handshake.
        // =====================================================================
        $display("\n[6] BURST 8 consecutive beats");
        do_reset;
        m_axis_tready = 1'b1;
        for (i = 0; i < 8; i = i + 1) begin
            drive_pred(i * 16'h0100, i * 16'h0080, i[7:0]);
            burst_data[i] = m_axis_tdata;  // capture while TVALID=1
            @(posedge clk); #1;            // complete handshake
        end
        for (i = 0; i < 8; i = i + 1) begin
            expected = {8'd0, i[7:0],
                        (i[15:0] * 16'h0080),
                        (i[15:0] * 16'h0100)};
            check("Burst beat x/y/conf correct", burst_data[i] === expected);
        end

        // =====================================================================
        // TEST 7 : PROTOCOL compliance under continuous stall
        // =====================================================================
        $display("\n[7] PROTOCOL -- TVALID stable while TREADY low");
        do_reset;
        m_axis_tready = 1'b0;
        drive_pred(16'hDEAD, 16'hBEEF, 8'hFF);
        begin : proto_blk
            integer violation;
            violation = 0;
            // Check current cycle, then 5 more
            repeat(6) begin
                if (m_axis_tvalid !== 1'b1) violation = violation + 1;
                @(posedge clk); #1;
            end
            check("TVALID stable for 6 stall cycles", violation === 0);
        end
        @(negedge clk); m_axis_tready = 1'b1;
        @(posedge clk); #1;

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
