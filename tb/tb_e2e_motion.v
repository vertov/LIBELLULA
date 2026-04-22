`timescale 1ns/1ps
`default_nettype none

// End-to-end motion bench: single point target moving at constant velocity
// across NUM_TILES tile columns (East direction). Validates full pipeline:
//   AER -> LIF(tile hash, LEAK_SHIFT=4) -> DelayLattice(STEP=64) ->
//   Reichardt -> BurstGate(WINDOW=1024,TH_OPEN=2) -> ab_predictor
//
// Injection strategy: SCAN-SYNCHRONIZED.
// Each event is held asserted until the scan_addr matches the target neuron
// address.  This guarantees every presented event lands as a hit, making
// accumulation deterministic: THRESH=16 hits → spike, independent of scan phase.
//
// Target trajectory: tile_x = 2..2+NUM_TILES-1, tile_y = 8 (fixed horizontal)
// Tile step = 64 pixels (XW=10, AW=8 → HX=4 → tile size=2^6=64).
//
// Pass criterion: pred_valid asserts at least once after ≥2 tile transitions.

module tb_e2e_motion;

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam XW        = 10;
    localparam YW        = 10;
    localparam AW        = 8;
    localparam DW        = 0;
    localparam PW        = 16;
    localparam HX        = AW / 2;          // = 4
    localparam HY        = AW - HX;         // = 4
    localparam TILE_STEP = 1 << (XW - HX);  // = 64 pixels per tile
    localparam THRESH    = 16;              // must match lif_tile_tmux
    localparam NUM_TILES = 10;
    localparam HITS_TILE = THRESH + 4;      // 20 guaranteed hits per tile (enough headroom)
    localparam MAX_CYC   = 1_000_000;

    // -----------------------------------------------------------------------
    // Clock / DUT
    // -----------------------------------------------------------------------
    reg clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    reg  rst = 1;
    reg  aer_req = 0;
    wire aer_ack;
    reg  [XW-1:0] aer_x = 0;
    reg  [YW-1:0] aer_y = 0;
    reg  aer_pol = 0;
    reg  [AW-1:0] scan_addr = 0;

    wire pred_valid;
    wire [PW-1:0] x_hat, y_hat;
    wire [7:0]    conf;
    wire          conf_valid;

    libellula_top #(
        .XW(XW), .YW(YW), .AW(AW), .DW(DW), .PW(PW),
        .TILE_STEP(TILE_STEP)
    ) dut (
        .clk(clk), .rst(rst),
        .aer_req(aer_req), .aer_ack(aer_ack),
        .aer_x(aer_x), .aer_y(aer_y), .aer_pol(aer_pol),
        .scan_addr(scan_addr),
        .pred_valid(pred_valid), .x_hat(x_hat), .y_hat(y_hat),
        .conf(conf), .conf_valid(conf_valid)
    );

    // Free-running scan counter
    always @(posedge clk)
        if (rst) scan_addr <= 0;
        else     scan_addr <= scan_addr + 1'b1;

    // -----------------------------------------------------------------------
    // Stage-activity monitoring
    // -----------------------------------------------------------------------
    wire lif_v = dut.lif_v;
    wire ds_v  = dut.ds_v;
    wire bg_v  = dut.bg_v;

    integer lif_spike_cnt   = 0;
    integer reichardt_cnt   = 0;
    integer burst_cnt       = 0;
    integer pred_cnt        = 0;
    integer first_lif_cyc   = -1;
    integer first_ds_cyc    = -1;
    integer first_burst_cyc = -1;
    integer first_pred_cyc  = -1;
    integer cyc             = 0;

    // Track current tile for display
    reg [3:0] cur_tile_x_r = 0;

    always @(posedge clk) begin
        if (!rst) cyc <= cyc + 1;
        if (!rst && lif_v) begin
            lif_spike_cnt <= lif_spike_cnt + 1;
            if (first_lif_cyc < 0) first_lif_cyc <= cyc;
        end
        if (!rst && ds_v) begin
            reichardt_cnt <= reichardt_cnt + 1;
            if (first_ds_cyc < 0) first_ds_cyc <= cyc;
        end
        if (!rst && bg_v) begin
            burst_cnt <= burst_cnt + 1;
            if (first_burst_cyc < 0) first_burst_cyc <= cyc;
        end
        if (!rst && pred_valid) begin
            pred_cnt <= pred_cnt + 1;
            if (first_pred_cyc < 0) first_pred_cyc <= cyc;
            $display("CYC=%0d  PRED x_hat=%0d y_hat=%0d  tile_x=%0d px_expected=%0d",
                     cyc, x_hat, y_hat, cur_tile_x_r,
                     {cur_tile_x_r, {(XW-HX){1'b0}}});
        end
    end

    // -----------------------------------------------------------------------
    // Scan-synchronized event injection
    // -----------------------------------------------------------------------
    // Compute the neuron address for a given (tx, ty) tile
    // hashed = {tx[HX-1:0], ty[HY-1:0]}
    function [AW-1:0] tile_addr;
        input [3:0] tx;
        input [3:0] ty;
        begin
            tile_addr = {tx[HX-1:0], ty[HY-1:0]};
        end
    endfunction

    // Send one scan-synchronized hit for neuron at address 'naddr'.
    // Holds aer_req=1 with the tile-origin event until scan_addr==naddr,
    // then drops req after one matching posedge (guaranteed hit).
    task send_scan_hit;
        input [AW-1:0] naddr;
        input [XW-1:0] ex;
        input [YW-1:0] ey;
        begin
            // Assert event
            @(negedge clk);
            aer_x   = ex;
            aer_y   = ey;
            aer_pol = 1'b1;
            aer_req = 1'b1;
            // Wait until scan_addr lines up with the target neuron address
            // (scan cycles every 256 clocks; worst-case wait = 255 cycles)
            while (scan_addr !== naddr) @(posedge clk);
            // Hold for the matching clock edge, then release
            @(negedge clk);
            aer_req = 1'b0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Main stimulus
    // -----------------------------------------------------------------------
    integer tile_idx, h;
    integer ev_total = 0;

    initial begin
        repeat(20) @(posedge clk);
        rst = 0;
        repeat(5)  @(posedge clk);

        for (tile_idx = 2; tile_idx < 2 + NUM_TILES; tile_idx = tile_idx + 1) begin
            cur_tile_x_r = tile_idx[3:0];
            // Send HITS_TILE scan-synchronized hits for this tile's neuron
            for (h = 0; h < HITS_TILE; h = h + 1) begin
                send_scan_hit(
                    tile_addr(tile_idx[3:0], 4'd8),
                    tile_idx[XW-1:0] * TILE_STEP + 16,
                    8 * TILE_STEP + 16
                );
                ev_total = ev_total + 1;
                // One-cycle gap to prevent back-to-back collisions on same scan match
                @(posedge clk);
            end
            // Let this tile's spike propagate before moving to next tile
            // (spike requires THRESH hits, then pipeline latency ~6 cycles)
            repeat(512) @(posedge clk);
        end

        // Drain pipeline
        repeat(4096) @(posedge clk);

        // -----------------------------------------------------------------------
        // Report
        // -----------------------------------------------------------------------
        $display("E2E_RESULT status=%s ev=%0d lif=%0d ds=%0d burst=%0d pred=%0d",
                 (pred_cnt > 0) ? "PASS" : "FAIL",
                 ev_total, lif_spike_cnt, reichardt_cnt, burst_cnt, pred_cnt);
        $display("E2E_FIRST  first_lif=%0d first_ds=%0d first_burst=%0d first_pred=%0d",
                 first_lif_cyc, first_ds_cyc, first_burst_cyc, first_pred_cyc);

        if (pred_cnt > 0)
            $display("PASS: pred_valid fired %0d times", pred_cnt);
        else
            $display("FAIL: pred_valid never asserted — check stage counts above");

        $finish;
    end

    // Safety watchdog
    initial begin
        #(MAX_CYC * 10);
        $display("TIMEOUT after %0d cycles — lif=%0d ds=%0d burst=%0d pred=%0d",
                 MAX_CYC, lif_spike_cnt, reichardt_cnt, burst_cnt, pred_cnt);
        $finish;
    end

endmodule

`default_nettype wire
