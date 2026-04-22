`timescale 1ns/1ps
`default_nettype none

// Multi-target bench using tracker_pool (NTRACK=4).
//
// Two targets at the same x-tile row, different y-tile rows:
//   Target A: tile_y=TYA, moving East tile_x=START_TX..START_TX+NUM_TILES
//   Target B: tile_y=TYB, same x-trajectory
//
// Hits for A and B are injected in the same tile-step: A's HITS_TILE hits,
// then B's HITS_TILE hits, then drain. Both LIF neurons fire independently.
// The tracker pool must spawn one tracker per target and track them separately.
//
// PASS criteria:
//   - Both targets produce pred_valid firings with track_id distinguishing them.
//   - Final mean y error for each target vs. its own track < 32px.
//   - Neither target's y predictions converge to the other target's y.

module tb_multi_target_pool;

    localparam XW=10, YW=10, AW=8, DW=0, PW=16;
    localparam NTRACK     = 4;
    localparam ASSIGN_TH  = 96;    // <<< target y-sep is 256px (>> 96)
    localparam TILE_STEP_I = 1;    // delay lattice tile-index step
    localparam HX         = AW/2;  // 4
    localparam TILE_PX    = 1 << (XW - HX);  // 64 pixels per tile
    localparam THRESH     = 16;
    localparam HITS_TILE  = THRESH + 4;

    localparam [3:0] TYA      = 4'd4;
    localparam [3:0] TYB      = 4'd8;
    localparam [3:0] START_TX = 4'd2;
    localparam       NUM_TILES = 8;
    localparam       DWELL_PAD = 512;

    localparam TRUE_YA = TYA * TILE_PX + 20;  // 276
    localparam TRUE_YB = TYB * TILE_PX + 20;  // 532

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    reg clk=0; always #5 clk=~clk;
    reg  rst=1, aer_req=0; wire aer_ack;
    reg  [XW-1:0] aer_x=0;
    reg  [YW-1:0] aer_y=0;
    reg  aer_pol=0;
    reg  [AW-1:0] scan_addr=0;
    wire pred_valid;
    wire [PW-1:0] x_hat, y_hat;
    wire [7:0]  conf; wire conf_valid;
    wire [1:0]  track_id;

    libellula_top #(
        .XW(XW), .YW(YW), .AW(AW), .DW(DW), .PW(PW),
        .TILE_STEP(TILE_STEP_I),
        .NTRACK(NTRACK), .ASSIGN_TH(ASSIGN_TH)
    ) dut (
        .clk(clk), .rst(rst),
        .aer_req(aer_req), .aer_ack(aer_ack),
        .aer_x(aer_x), .aer_y(aer_y), .aer_pol(aer_pol),
        .scan_addr(scan_addr),
        .pred_valid(pred_valid), .x_hat(x_hat), .y_hat(y_hat),
        .conf(conf), .conf_valid(conf_valid),
        .track_id(track_id)
    );

    always @(posedge clk)
        if (rst) scan_addr <= 0;
        else     scan_addr <= scan_addr + 1'b1;

    // -------------------------------------------------------------------------
    // Scan-sync injection (one hit per scan period — hold req until scan matches)
    // -------------------------------------------------------------------------
    localparam HY = AW - HX;
    function [AW-1:0] tile_addr;
        input [3:0] tx; input [3:0] ty;
        tile_addr = {tx[HX-1:0], ty[HY-1:0]};
    endfunction

    task send_hit;
        input [AW-1:0] naddr;
        input [XW-1:0] ex;
        input [YW-1:0] ey;
        begin
            @(negedge clk);
            aer_x = ex; aer_y = ey; aer_pol = 1'b1; aer_req = 1'b1;
            while (scan_addr !== naddr) @(posedge clk);
            @(negedge clk);
            aer_req = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Per-track accuracy tracking (4 trackers, 2 real targets)
    // -------------------------------------------------------------------------
    integer pred_cnt_a=0, pred_cnt_b=0;
    integer err_ya_sum=0, err_yb_sum=0;
    integer err_ya_max=0, err_yb_max=0;
    integer abs_ya, abs_yb;

    // Which track_id ended up tracking A vs B (inferred from first close hit)
    reg [1:0] track_a = 2'd0, track_b = 2'd1;
    reg track_a_known = 1'b0, track_b_known = 1'b0;

    integer cyc=0;
    integer true_x_now=0;

    always @(posedge clk) begin
        if (!rst) cyc <= cyc + 1;
        if (!rst && pred_valid) begin
            abs_ya = (y_hat >= TRUE_YA) ? (y_hat - TRUE_YA) : (TRUE_YA - y_hat);
            abs_yb = (y_hat >= TRUE_YB) ? (y_hat - TRUE_YB) : (TRUE_YB - y_hat);

            // Identify which track this is (first close prediction determines mapping)
            if (!track_a_known && abs_ya < 32) begin
                track_a       <= track_id;
                track_a_known <= 1'b1;
            end
            if (!track_b_known && abs_yb < 32) begin
                track_b       <= track_id;
                track_b_known <= 1'b1;
            end

            // Accumulate error for the assigned track
            if (track_a_known && track_id == track_a) begin
                pred_cnt_a <= pred_cnt_a + 1;
                err_ya_sum <= err_ya_sum + abs_ya;
                if (abs_ya > err_ya_max) err_ya_max <= abs_ya;
            end
            if (track_b_known && track_id == track_b) begin
                pred_cnt_b <= pred_cnt_b + 1;
                err_yb_sum <= err_yb_sum + abs_yb;
                if (abs_yb > err_yb_max) err_yb_max <= abs_yb;
            end

            $display("CYC=%0d TID=%0d x_hat=%0d y_hat=%0d  err_ya=%0d err_yb=%0d",
                     cyc, track_id, x_hat, y_hat, abs_ya, abs_yb);
        end
    end

    // -------------------------------------------------------------------------
    // Stimulus
    // -------------------------------------------------------------------------
    integer ti, h;

    initial begin
        repeat(20) @(posedge clk); rst = 0; repeat(5) @(posedge clk);

        for (ti = START_TX; ti < START_TX + NUM_TILES; ti = ti + 1) begin
            true_x_now = ti * TILE_PX + 20;

            // Inject HITS_TILE events for target A at this x-position
            for (h = 0; h < HITS_TILE; h = h + 1) begin
                send_hit(tile_addr(ti[3:0], TYA),
                         ti[XW-1:0] * TILE_PX + 20,
                         TYA * TILE_PX + 20);
                @(posedge clk);
            end

            // Inject HITS_TILE events for target B at same x-position
            for (h = 0; h < HITS_TILE; h = h + 1) begin
                send_hit(tile_addr(ti[3:0], TYB),
                         ti[XW-1:0] * TILE_PX + 20,
                         TYB * TILE_PX + 20);
                @(posedge clk);
            end

            repeat(DWELL_PAD) @(posedge clk);
        end
        repeat(4096) @(posedge clk);

        // ----------------------------------------------------------------
        // Results
        // ----------------------------------------------------------------
        $display("POOL_RESULT  pred_a=%0d pred_b=%0d  track_a=%0d track_b=%0d",
                 pred_cnt_a, pred_cnt_b, track_a, track_b);

        if (pred_cnt_a > 0)
            $display("POOL_Y_A mean_err=%0d max_err=%0d  (true_yA=%0d)",
                     err_ya_sum / pred_cnt_a, err_ya_max, TRUE_YA);
        else
            $display("POOL_Y_A FAIL: no predictions for target A");

        if (pred_cnt_b > 0)
            $display("POOL_Y_B mean_err=%0d max_err=%0d  (true_yB=%0d)",
                     err_yb_sum / pred_cnt_b, err_yb_max, TRUE_YB);
        else
            $display("POOL_Y_B FAIL: no predictions for target B");

        if (pred_cnt_a > 0 && pred_cnt_b > 0 &&
            err_ya_max <= 32 && err_yb_max <= 32 &&
            track_a !== track_b)
            $display("POOL_VERDICT PASS: two targets tracked on separate tracks");
        else if (pred_cnt_a == 0 || pred_cnt_b == 0)
            $display("POOL_VERDICT FAIL: one or both targets not tracked");
        else if (track_a == track_b)
            $display("POOL_VERDICT FAIL: both targets assigned to same track");
        else
            $display("POOL_VERDICT PARTIAL: tracked but error > 32px (max_a=%0d max_b=%0d)",
                     err_ya_max, err_yb_max);

        $finish;
    end

    initial begin #2000000000; $display("TIMEOUT"); $finish; end

endmodule

`default_nettype wire
