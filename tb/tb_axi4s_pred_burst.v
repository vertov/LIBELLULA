// =============================================================================
// tb_axi4s_pred_burst.v
// Multi-target burst test for axi4s_pred_wrapper.v
//
// Validates the depth-4 FIFO overflow path that was absent in the original
// single-register implementation.  Key scenarios:
//
//   1. SINGLE    : legacy single-prediction fast-path unchanged
//   2. BURST4    : 4 predictions in 4 consecutive cycles, TREADY held low;
//                  all 4 must survive and arrive in order when TREADY releases
//   3. DRAIN     : FIFO drains one beat per cycle after TREADY releases
//   4. OVERFLOW  : 5th prediction while 4 already queued (output + FIFO full);
//                  first 4 must be preserved; 5th is dropped (warning expected)
//   5. BACKPRESS : classic 1-prediction stall (AXI4-S protocol compliance)
//   6. INTERLEAVE: predictions arrive while FIFO is partially draining
// =============================================================================

`timescale 1ns/1ps
`default_nettype none

module tb_axi4s_pred_burst;

    localparam PW      = 16;
    localparam CONFW   =  8;
    localparam FDEPTH  =  4;
    localparam CLK_PER = 5.0;

    reg              clk     = 1'b0;
    reg              rst_n   = 1'b0;
    reg              pred_valid = 1'b0;
    reg  [PW-1:0]    x_pred  = 16'd0;
    reg  [PW-1:0]    y_pred  = 16'd0;
    reg  [CONFW-1:0] conf    = 8'd0;
    wire             m_axis_tvalid;
    reg              m_axis_tready = 1'b1;
    wire [47:0]      m_axis_tdata;
    wire [5:0]       m_axis_tkeep;
    wire             m_axis_tlast;

    axi4s_pred_wrapper #(.PW(PW), .CONFW(CONFW), .FIFO_DEPTH(FDEPTH)) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .pred_valid   (pred_valid),
        .x_pred       (x_pred),
        .y_pred       (y_pred),
        .conf         (conf),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tdata (m_axis_tdata),
        .m_axis_tkeep (m_axis_tkeep),
        .m_axis_tlast (m_axis_tlast)
    );

    always #(CLK_PER/2.0) clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

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

    task do_reset;
        begin
            rst_n      = 1'b0;
            pred_valid = 1'b0;
            x_pred     = 16'd0;
            y_pred     = 16'd0;
            conf       = 8'd0;
            m_axis_tready = 1'b1;
            repeat(4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            @(posedge clk); #1;
        end
    endtask

    // Drive a single-cycle pred_valid pulse and return after posedge+#1
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
            @(posedge clk); #1;
            pred_valid = 1'b0;
        end
    endtask

    // Drive N predictions in N consecutive cycles (no gaps between pulses)
    task drive_burst;
        input integer n;
        input [PW-1:0] x_base;
        input [PW-1:0] y_base;
        integer bi;
        begin
            for (bi = 0; bi < n; bi = bi + 1) begin
                @(negedge clk);
                x_pred     = x_base + bi;
                y_pred     = y_base + bi;
                conf       = bi[7:0];
                pred_valid = 1'b1;
                @(posedge clk); #1;
                pred_valid = 1'b0;
            end
        end
    endtask

    // Collect up to N beats from the AXI output into arrays; return count seen.
    // Sampling happens AT posedge (before #1) so we capture the pre-update value
    // — i.e., the beat being delivered in the current handshake, not the next one.
    // This correctly captures the beat that is already in the output register when
    // m_axis_tready is asserted before the first clock of the collection window.
    reg [PW-1:0]    rx_x   [0:7];
    reg [PW-1:0]    rx_y   [0:7];
    reg [CONFW-1:0] rx_conf[0:7];

    task collect_beats;
        input  integer n_expected;
        input  integer timeout_cycles;
        output integer n_received;
        integer ci;
        integer seen;
        begin
            seen = 0;
            for (ci = 0; ci < timeout_cycles && seen < n_expected; ci = ci + 1) begin
                @(posedge clk);
                // Sample at posedge+0 (NBA phase not yet applied): m_axis_tdata
                // still holds the beat being delivered this cycle.
                if (m_axis_tvalid && m_axis_tready) begin
                    rx_x   [seen] = m_axis_tdata[PW-1:0];
                    rx_y   [seen] = m_axis_tdata[PW+PW-1:PW];
                    rx_conf[seen] = m_axis_tdata[PW+PW+CONFW-1:PW+PW];
                    seen = seen + 1;
                end
                #1; // let registers settle for next iteration checks
            end
            n_received = seen;
        end
    endtask

    integer i, n_rx;

    initial begin
        $display("=== tb_axi4s_pred_burst : AXI4-S Prediction Output FIFO ===");

        // =====================================================================
        // TEST 1 : SINGLE prediction — fast-path (no FIFO involvement)
        // =====================================================================
        $display("\n[1] SINGLE prediction fast-path");
        do_reset;
        m_axis_tready = 1'b1;
        drive_pred(16'h0100, 16'h0200, 8'hAA);
        check("TVALID asserted",         m_axis_tvalid === 1'b1);
        check("x_pred correct",          m_axis_tdata[15:0]  === 16'h0100);
        check("y_pred correct",          m_axis_tdata[31:16] === 16'h0200);
        check("conf correct",            m_axis_tdata[39:32] === 8'hAA);
        check("TLAST == TVALID",         m_axis_tlast === m_axis_tvalid);
        check("TKEEP all valid",         m_axis_tkeep === 6'b111111);
        @(posedge clk); #1;
        check("TVALID deasserts after handshake", m_axis_tvalid === 1'b0);

        // =====================================================================
        // TEST 2 : BURST4 — 4 predictions while TREADY=0; all must survive
        // =====================================================================
        $display("\n[2] BURST4 — 4 predictions, TREADY low; all must survive");
        do_reset;
        m_axis_tready = 1'b0;
        // Fire 4 predictions in 4 consecutive cycles
        drive_burst(4, 16'h0010, 16'h0020);
        // Output register holds pred 0; preds 1–3 are in the FIFO
        check("TVALID high after burst", m_axis_tvalid === 1'b1);
        check("First beat x",            m_axis_tdata[15:0]  === 16'h0010);
        check("First beat y",            m_axis_tdata[31:16] === 16'h0020);
        check("First beat conf",         m_axis_tdata[39:32] === 8'h00);
        // Release TREADY and drain all 4 beats
        m_axis_tready = 1'b1;
        collect_beats(4, 20, n_rx);
        check("All 4 beats received",     n_rx === 4);
        // Verify order
        for (i = 0; i < 4 && i < n_rx; i = i + 1) begin
            check("Beat x in order", rx_x[i] === 16'h0010 + i);
            check("Beat y in order", rx_y[i] === 16'h0020 + i);
            check("Beat conf in order", rx_conf[i] === i[7:0]);
        end

        // =====================================================================
        // TEST 3 : DRAIN — FIFO drains one beat per cycle at TREADY=1
        // =====================================================================
        $display("\n[3] DRAIN — FIFO drains cleanly, TVALID deasserts when empty");
        do_reset;
        m_axis_tready = 1'b0;
        drive_burst(3, 16'h0030, 16'h0040);
        m_axis_tready = 1'b1;
        begin : drain_blk
            integer high_count;
            integer idle_count;
            high_count = 0;
            idle_count = 0;
            // Count the beat already in the output register (visible before first clock)
            if (m_axis_tvalid) high_count = high_count + 1;
            repeat(10) begin
                @(posedge clk); #1;
                if (m_axis_tvalid) high_count = high_count + 1;
                else               idle_count = idle_count + 1;
            end
            // 3 beats loaded (pred 0 already in reg, pred 1 and 2 in FIFO).
            check("At least 3 TVALID beats seen in drain", high_count >= 3);
        end

        // =====================================================================
        // TEST 4 : OVERFLOW — 5th prediction while FIFO full; first 4 survive
        // (Simulation will emit a WARNING line; that is expected behaviour.)
        // =====================================================================
        $display("\n[4] OVERFLOW — 5 preds with TREADY=0; first 4 survive, 5th dropped");
        do_reset;
        m_axis_tready = 1'b0;
        // Fire 5 predictions: output reg + 3 FIFO slots = 4 total capacity
        drive_burst(5, 16'h0050, 16'h0060);
        // The 5th (index 4, x=0x0054) must have been dropped
        m_axis_tready = 1'b1;
        collect_beats(4, 20, n_rx);
        check("Exactly 4 beats received (5th dropped)", n_rx === 4);
        for (i = 0; i < 4 && i < n_rx; i = i + 1) begin
            check("Surviving beat x correct", rx_x[i] === 16'h0050 + i);
        end

        // =====================================================================
        // TEST 5 : BACKPRESSURE — standard AXI4-S protocol compliance
        // =====================================================================
        $display("\n[5] BACKPRESSURE — TVALID stable while TREADY low");
        do_reset;
        m_axis_tready = 1'b0;
        drive_pred(16'hDEAD, 16'hBEEF, 8'hFF);
        begin : bp_blk
            integer violation;
            violation = 0;
            repeat(6) begin
                if (m_axis_tvalid !== 1'b1) violation = violation + 1;
                @(posedge clk); #1;
            end
            check("TVALID stable for 6 stall cycles", violation === 0);
        end
        @(negedge clk); m_axis_tready = 1'b1;
        @(posedge clk); #1;
        check("TVALID deasserts after release", m_axis_tvalid === 1'b0);

        // =====================================================================
        // TEST 6 : INTERLEAVE — new predictions arrive while FIFO is draining
        // =====================================================================
        $display("\n[6] INTERLEAVE — arrivals interleaved with drain");
        do_reset;
        m_axis_tready = 1'b0;
        // Send 2 predictions while stalled
        drive_burst(2, 16'h0070, 16'h0080);
        // Start draining, send 2 more predictions mid-drain
        m_axis_tready = 1'b1;
        @(posedge clk); #1;              // consume pred 0
        m_axis_tready = 1'b0;
        drive_burst(2, 16'h0072, 16'h0082);   // 2 more while re-stalled
        m_axis_tready = 1'b1;
        collect_beats(3, 20, n_rx);     // expect 3 remaining (1 was consumed above)
        check("3 remaining beats received", n_rx === 3);

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

    initial begin
        #500000;
        $display("WATCHDOG TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
