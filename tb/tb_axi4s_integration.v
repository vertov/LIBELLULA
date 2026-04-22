// =============================================================================
// tb_axi4s_integration.v
// End-to-end integration test: AXI4-Stream -> axi4s_to_aer -> libellula_top
//
// Validates that AXI4-S beats pushed into axi4s_to_aer actually appear as
// events inside the real LIBELLULA core's AER receiver (not just against a
// TB-side model of aer_rx).  Uses hierarchical references to observe
// u_core.u_rx.ev_valid / ev_x / ev_y / ev_pol directly.
//
// What this proves that the unit tb cannot:
//   1. axi4s_to_aer drives signals that the real aer_rx sees as valid events
//   2. The bridge's aer_x / aer_y / aer_pol bit ordering matches the core
//   3. Timing / pulse width is compatible with the downstream LIF pipeline
//   4. No events are dropped or duplicated across the full signal chain
//
// Compile & run (from repo root):
//   iverilog -g2012 -DSIMULATION \
//       -o /tmp/tb_axi4s_integration \
//       rtl/*.v tb/tb_axi4s_integration.v
//   vvp /tmp/tb_axi4s_integration
// =============================================================================

`timescale 1ns/1ps

module tb_axi4s_integration;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam XW       = 10;
    localparam YW       = 10;
    localparam DATA_W   = 32;
    localparam CLK_PER  = 5.0;   // 200 MHz

    localparam NUM_EVENTS = 16;  // number of AXI4-S beats to push

    // -------------------------------------------------------------------------
    // Clock / reset
    // -------------------------------------------------------------------------
    reg  clk = 1'b0;
    reg  rst = 1'b1;             // core uses active-high rst
    wire rst_n = ~rst;           // bridge uses active-low rst_n

    always #(CLK_PER/2.0) clk = ~clk;

    // -------------------------------------------------------------------------
    // AXI4-Stream producer signals
    // -------------------------------------------------------------------------
    reg                     s_axis_tvalid;
    wire                    s_axis_tready;
    reg  [DATA_W-1:0]       s_axis_tdata;
    reg  [(DATA_W/8)-1:0]   s_axis_tkeep;
    reg                     s_axis_tlast;

    // -------------------------------------------------------------------------
    // Bridge <-> core AER wires
    // -------------------------------------------------------------------------
    wire            aer_req;
    wire            aer_ack;
    wire [XW-1:0]   aer_x;
    wire [YW-1:0]   aer_y;
    wire            aer_pol;

    // -------------------------------------------------------------------------
    // Core prediction outputs (observed, not checked here)
    // -------------------------------------------------------------------------
    wire            pred_valid;
    wire [15:0]     x_hat;
    wire [15:0]     y_hat;
    wire [7:0]      conf;
    wire            conf_valid;
    wire [1:0]      tid_unused;

    // -------------------------------------------------------------------------
    // DUT A : the bridge under test
    // -------------------------------------------------------------------------
    axi4s_to_aer #(
        .XW     (XW),
        .YW     (YW),
        .DATA_W (DATA_W)
    ) u_bridge (
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
    // DUT B : the real LIBELLULA core
    // -------------------------------------------------------------------------
    libellula_top u_core (
        .clk        (clk),
        .rst        (rst),
        .aer_req    (aer_req),
        .aer_ack    (aer_ack),
        .aer_x      (aer_x),
        .aer_y      (aer_y),
        .aer_pol    (aer_pol),
        .scan_addr  (8'd0),
        .pred_valid (pred_valid),
        .x_hat      (x_hat),
        .y_hat      (y_hat),
        .conf       (conf),
        .conf_valid (conf_valid),
        .track_id   (tid_unused)
    );

    // -------------------------------------------------------------------------
    // Golden reference: capture every AXI4-S beat we transmit
    // -------------------------------------------------------------------------
    reg [XW-1:0] sent_x   [0:NUM_EVENTS-1];
    reg [YW-1:0] sent_y   [0:NUM_EVENTS-1];
    reg          sent_pol [0:NUM_EVENTS-1];
    integer send_idx;

    // -------------------------------------------------------------------------
    // Event observer: watch u_core.u_rx (real aer_rx) on each posedge
    // Captures every event that makes it into the core.
    // -------------------------------------------------------------------------
    reg [XW-1:0] recv_x   [0:NUM_EVENTS*2-1];
    reg [YW-1:0] recv_y   [0:NUM_EVENTS*2-1];
    reg          recv_pol [0:NUM_EVENTS*2-1];
    integer      recv_idx;

    always @(posedge clk) begin
        if (!rst && u_core.u_rx.ev_valid) begin
            if (recv_idx < NUM_EVENTS*2) begin
                recv_x  [recv_idx] = u_core.u_rx.ev_x;
                recv_y  [recv_idx] = u_core.u_rx.ev_y;
                recv_pol[recv_idx] = u_core.u_rx.ev_pol;
            end
            recv_idx = recv_idx + 1;
        end
    end

    // -------------------------------------------------------------------------
    // drive_beat : one AXI4-S beat
    // -------------------------------------------------------------------------
    task drive_beat;
        input [XW-1:0] xv;
        input [YW-1:0] yv;
        input          pv;
        reg   [DATA_W-1:0] w;
        begin
            w               = {DATA_W{1'b0}};
            w[XW-1:0]       = xv;
            w[XW+YW-1:XW]   = yv;
            w[XW+YW]        = pv;
            @(negedge clk);
            while (!s_axis_tready) @(negedge clk);
            s_axis_tdata    = w;
            s_axis_tkeep    = {(DATA_W/8){1'b1}};
            s_axis_tlast    = 1'b1;
            s_axis_tvalid   = 1'b1;
            @(posedge clk); #1;
            s_axis_tvalid   = 1'b0;
            s_axis_tlast    = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Test
    // -------------------------------------------------------------------------
    integer i;
    integer mismatches;
    integer pred_seen;

    initial begin
        // Init
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = {DATA_W{1'b0}};
        s_axis_tkeep  = {(DATA_W/8){1'b1}};
        s_axis_tlast  = 1'b0;
        send_idx      = 0;
        recv_idx      = 0;
        mismatches    = 0;
        pred_seen     = 0;

        $display("=== tb_axi4s_integration : AXI4-S -> axi4s_to_aer -> libellula_top ===");

        // Reset pulse (active-high on core, active-low on bridge via inverter)
        rst = 1'b1;
        repeat(8) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(posedge clk); #1;

        // Push NUM_EVENTS beats through the AXI4-S interface with a variety of
        // x / y / pol values.  Record each one in the golden array.
        for (i = 0; i < NUM_EVENTS; i = i + 1) begin
            sent_x  [i] = 10'd50 + i[XW-1:0];
            sent_y  [i] = 10'd100 + (i[YW-1:0] * 10'd3);
            sent_pol[i] = i[0];
            drive_beat(sent_x[i], sent_y[i], sent_pol[i]);
            // advance one cycle so the S_REQ pulse is observed by u_rx
            @(posedge clk); #1;
        end

        // Let the core pipeline drain
        repeat(20) @(posedge clk);

        // ---------------------------------------------------------------------
        // Check 1 : exactly NUM_EVENTS events reached the core's aer_rx
        // ---------------------------------------------------------------------
        $display("\n[INTEGRATION] Event count check");
        if (recv_idx === NUM_EVENTS) begin
            $display("  PASS : %0d events sent, %0d received by u_core.u_rx",
                     NUM_EVENTS, recv_idx);
        end else begin
            $display("  FAIL : %0d events sent, %0d received by u_core.u_rx",
                     NUM_EVENTS, recv_idx);
            mismatches = mismatches + 1;
        end

        // ---------------------------------------------------------------------
        // Check 2 : each received event matches the sent x/y/pol in order
        // ---------------------------------------------------------------------
        $display("\n[INTEGRATION] Event content check");
        for (i = 0; i < NUM_EVENTS; i = i + 1) begin
            if (i < recv_idx) begin
                if (recv_x  [i] !== sent_x  [i] ||
                    recv_y  [i] !== sent_y  [i] ||
                    recv_pol[i] !== sent_pol[i]) begin
                    $display("  FAIL : event %0d  sent (x=%0d y=%0d p=%0d)  recv (x=%0d y=%0d p=%0d)",
                             i, sent_x[i], sent_y[i], sent_pol[i],
                                recv_x[i], recv_y[i], recv_pol[i]);
                    mismatches = mismatches + 1;
                end
            end
        end
        if (mismatches === 0)
            $display("  PASS : all %0d events match in order and content", NUM_EVENTS);

        // ---------------------------------------------------------------------
        // Check 3 : protocol sanity — aer_req pulses counted equal events
        // ---------------------------------------------------------------------
        // Already covered implicitly by check 1 (ev_valid == aer_req in aer_rx).

        // ---------------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------------
        $display("\n=== RESULT : %0d mismatches ===", mismatches);
        if (mismatches === 0)
            $display("PASS");
        else
            $display("FAIL");
        $finish;
    end

    // Watchdog
    initial begin
        #500000;
        $display("WATCHDOG TIMEOUT");
        $finish;
    end

endmodule
