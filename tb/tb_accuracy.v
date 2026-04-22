`timescale 1ns/1ps
`default_nettype none

// Prediction accuracy bench.
// A single target moves at constant velocity VX_PIX pixels per tile-scan-period.
// Scan-synchronised injection guarantees clean hits.  At each pred_valid we
// compare x_hat against the true target pixel position and accumulate:
//   - absolute error per prediction
//   - max error
//   - mean error (sum / count)
//
// The "true" position is computed from the tile centres: the target advances
// by VX_TILES tile columns per update, emitting the exact pixel (tile*TILE_STEP+OFFSET).
// Because the predictor now uses exact event coords (out_ex) the error should
// converge toward sub-tile accuracy as the alpha-beta filter warms up.

module tb_accuracy;

    localparam XW        = 10;
    localparam YW        = 10;
    localparam AW        = 8;
    localparam DW        = 0;
    localparam PW        = 16;
    localparam HX        = AW/2;               // 4
    localparam TILE_STEP = 1 << (XW - HX);     // 64 px per tile
    localparam THRESH    = 16;
    localparam HITS_TILE = THRESH + 4;          // 20 guaranteed hits per tile

    // Motion parameters
    localparam VX_TILES  = 1;      // tile steps per update (constant velocity)
    localparam TY_FIXED  = 4'd8;   // fixed tile row (y axis, no motion)
    localparam START_TX  = 4'd2;   // starting tile column
    localparam NUM_STEPS = 12;     // number of tile advances
    localparam EV_OFFSET = 10'd20; // pixel offset within tile for injected events

    localparam MAX_CYC   = 1_500_000;

    // -----------------------------------------------------------------------
    // Clock / DUT
    // -----------------------------------------------------------------------
    reg clk = 0;
    always #5 clk = ~clk;

    reg  rst = 1;
    reg  aer_req = 0;
    wire aer_ack;
    reg  [XW-1:0] aer_x = 0;
    reg  [YW-1:0] aer_y = 0;
    reg  aer_pol = 0;
    reg  [AW-1:0] scan_addr = 0;

    wire pred_valid;
    wire [PW-1:0] x_hat, y_hat;
    wire [7:0] conf;
    wire conf_valid;

    // NOTE: libellula_top.TILE_STEP is the delay-lattice step in TILE-INDEX units
    // (always 1 when using lif_tile_tmux). TILE_STEP above (=64) is pixel tile width
    // used only for coordinate math in this bench — do NOT pass it to libellula_top.
    libellula_top #(
        .XW(XW), .YW(YW), .AW(AW), .DW(DW), .PW(PW),
        .TILE_STEP(1)
    ) dut (
        .clk(clk), .rst(rst),
        .aer_req(aer_req), .aer_ack(aer_ack),
        .aer_x(aer_x), .aer_y(aer_y), .aer_pol(aer_pol),
        .scan_addr(scan_addr),
        .pred_valid(pred_valid), .x_hat(x_hat), .y_hat(y_hat),
        .conf(conf), .conf_valid(conf_valid)
    );

    always @(posedge clk)
        if (rst) scan_addr <= 0;
        else     scan_addr <= scan_addr + 1'b1;

    // -----------------------------------------------------------------------
    // Accuracy tracking
    // -----------------------------------------------------------------------
    integer pred_cnt   = 0;
    integer err_sum    = 0;  // sum of |x_hat - x_true|
    integer err_max    = 0;
    integer err_y_sum  = 0;
    integer err_y_max  = 0;
    integer cyc        = 0;

    // True target position at each pred_valid (set by stimulus before drain)
    integer true_x = 0;
    integer true_y = 0;
    integer abs_err_x, abs_err_y;

    wire lif_v = dut.lif_v;
    wire ds_v  = dut.ds_v;
    wire bg_v  = dut.bg_v;
    integer lif_cnt = 0, ds_cnt = 0, burst_cnt = 0;

    always @(posedge clk) begin
        if (!rst) cyc <= cyc + 1;
        if (!rst && lif_v)  lif_cnt   <= lif_cnt + 1;
        if (!rst && ds_v)   ds_cnt    <= ds_cnt + 1;
        if (!rst && bg_v)   burst_cnt <= burst_cnt + 1;
        if (!rst && pred_valid) begin
            abs_err_x = (x_hat >= true_x) ? (x_hat - true_x) : (true_x - x_hat);
            abs_err_y = (y_hat >= true_y) ? (y_hat - true_y) : (true_y - y_hat);
            pred_cnt <= pred_cnt + 1;
            err_sum  <= err_sum + abs_err_x;
            err_y_sum <= err_y_sum + abs_err_y;
            if (abs_err_x > err_max) err_max <= abs_err_x;
            if (abs_err_y > err_y_max) err_y_max <= abs_err_y;
            $display("CYC=%0d PRED x_hat=%0d y_hat=%0d true_x=%0d true_y=%0d err_x=%0d err_y=%0d",
                     cyc, x_hat, y_hat, true_x, true_y, abs_err_x, abs_err_y);
        end
    end

    // -----------------------------------------------------------------------
    // Scan-sync injection helper (identical to tb_e2e_motion)
    // -----------------------------------------------------------------------
    localparam HY = AW - HX;

    function [AW-1:0] tile_addr;
        input [3:0] tx; input [3:0] ty;
        tile_addr = {tx[HX-1:0], ty[HY-1:0]};
    endfunction

    // send_scan_hit: inject one event at the neuron's scan slot.
    // Assert aer_req and hold it until scan_addr reaches the target address;
    // the LIF counts exactly one hit (hit_comb fires only when scan_addr==hashed_xy).
    task send_scan_hit;
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

    // -----------------------------------------------------------------------
    // Stimulus: constant-velocity horizontal motion
    // -----------------------------------------------------------------------
    integer step_idx, h, ev_total;
    integer cur_tx;

    initial begin
        ev_total = 0;
        repeat(20) @(posedge clk);
        rst = 0;
        repeat(5)  @(posedge clk);

        for (step_idx = 0; step_idx < NUM_STEPS; step_idx = step_idx + 1) begin
            cur_tx = START_TX + step_idx * VX_TILES;
            // True target = pixel at (tile_origin + EV_OFFSET) — exactly what we inject
            true_x = cur_tx * TILE_STEP + EV_OFFSET;
            true_y = TY_FIXED * TILE_STEP + EV_OFFSET;

            for (h = 0; h < HITS_TILE; h = h + 1) begin
                send_scan_hit(
                    tile_addr(cur_tx[3:0], TY_FIXED),
                    cur_tx[XW-1:0] * TILE_STEP + EV_OFFSET,
                    TY_FIXED * TILE_STEP + EV_OFFSET
                );
                ev_total = ev_total + 1;
                @(posedge clk);
            end
            // Drain: wait for any pending pipeline activity to flush
            repeat(512) @(posedge clk);
        end

        // Final drain
        repeat(8192) @(posedge clk);

        // -----------------------------------------------------------------------
        // Summary report
        // -----------------------------------------------------------------------
        $display("ACC_RESULT status=%s preds=%0d ev=%0d lif=%0d ds=%0d burst=%0d",
                 (pred_cnt > 0) ? "PASS" : "FAIL",
                 pred_cnt, ev_total, lif_cnt, ds_cnt, burst_cnt);
        if (pred_cnt > 0) begin
            $display("ACC_ERROR  mean_x=%0d.%01d max_x=%0d  mean_y=%0d.%01d max_y=%0d  (pixels)",
                     err_sum / pred_cnt,
                     (err_sum * 10 / pred_cnt) % 10,
                     err_max,
                     err_y_sum / pred_cnt,
                     (err_y_sum * 10 / pred_cnt) % 10,
                     err_y_max);
            if (err_max <= 2 && err_y_max <= 2)
                $display("CLAIM_CHECK PASS: peak error ≤2px in both axes");
            else if (err_max <= 32)
                $display("CLAIM_CHECK PARTIAL: peak error %0dpx (tile-size limited; need higher AW for ≤2px)", err_max);
            else
                $display("CLAIM_CHECK FAIL: peak error %0dpx", err_max);
        end else
            $display("FAIL: pred_valid never asserted");

        $finish;
    end

    initial begin
        #(MAX_CYC * 10);
        $display("TIMEOUT — lif=%0d ds=%0d burst=%0d pred=%0d", lif_cnt, ds_cnt, burst_cnt, pred_cnt);
        $finish;
    end

endmodule

`default_nettype wire
