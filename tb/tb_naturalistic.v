`timescale 1ns/1ps
`default_nettype none

// Naturalistic injection bench (v2).
//
// Models a real DVS camera scenario: a bright moving target generates events
// continuously (aer_req held high).  The LIF scan visits the target's tile
// address once per 256 cycles, registering one hit per visit.  With
// LEAK_SHIFT=4 the LIF fixed-point is state=16=THRESH, so it spikes each
// visit once accumulated.
//
// The target moves East across NUM_TILES tiles.  Events are NOT scan-
// synchronised: aer_req is simply held high at the current tile pixel for
// DWELL_CYCLES cycles, then shifted to the next tile.  There is no explicit
// wait for a scan match.
//
// This validates that the pipeline works under continuous (non-synchronized)
// event generation, i.e. the realistic DVS operating mode.

module tb_naturalistic;

    localparam XW         = 10;
    localparam YW         = 10;
    localparam AW         = 8;
    localparam DW         = 0;
    localparam PW         = 16;
    localparam HX         = AW/2;
    localparam TILE_STEP  = 1 << (XW - HX);   // 64 px
    // Dwell time per tile.  Must be long enough for THRESH hits plus margin.
    // With continuous aer_req, 1 hit per 256-cycle scan period.
    // THRESH=16 → need ≥16 scan periods = 16*256 = 4096 cycles.
    // Use 6000 for margin + some pipeline drain time.
    localparam DWELL_CYCLES = 6000;
    localparam NUM_TILES  = 10;
    localparam TY_FIXED   = 4'd8;
    localparam START_TX   = 4'd2;
    localparam MAX_CYC    = 500_000;

    reg clk = 0;
    always #5 clk = ~clk;

    reg  rst = 1;
    reg  aer_req = 0;
    wire aer_ack;
    reg  [XW-1:0] aer_x = 0;
    reg  [YW-1:0] aer_y = 0;
    reg  aer_pol = 1;
    reg  [AW-1:0] scan_addr = 0;

    wire pred_valid;
    wire [PW-1:0] x_hat, y_hat;
    wire [7:0] conf;
    wire conf_valid;

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

    always @(posedge clk)
        if (rst) scan_addr <= 0;
        else     scan_addr <= scan_addr + 1'b1;

    wire lif_v = dut.lif_v;
    wire ds_v  = dut.ds_v;
    wire bg_v  = dut.bg_v;

    integer lif_cnt  = 0, ds_cnt = 0, burst_cnt = 0, pred_cnt = 0;
    integer first_pred_cyc = -1;
    integer cyc = 0;

    always @(posedge clk) begin
        if (!rst) cyc <= cyc + 1;
        if (!rst && lif_v)  lif_cnt  <= lif_cnt  + 1;
        if (!rst && ds_v)   ds_cnt   <= ds_cnt   + 1;
        if (!rst && bg_v)   burst_cnt<= burst_cnt + 1;
        if (!rst && pred_valid) begin
            pred_cnt <= pred_cnt + 1;
            if (first_pred_cyc < 0) first_pred_cyc <= cyc;
            $display("CYC=%0d NAT PRED x_hat=%0d y_hat=%0d", cyc, x_hat, y_hat);
        end
    end

    // -----------------------------------------------------------------------
    // Stimulus: hold aer_req=1 at current tile for DWELL_CYCLES, then advance
    // -----------------------------------------------------------------------
    integer tile_idx, dw;
    integer ev_cycles = 0;

    initial begin
        repeat(20) @(posedge clk);
        rst = 0;
        repeat(5) @(posedge clk);

        for (tile_idx = START_TX; tile_idx < START_TX + NUM_TILES; tile_idx = tile_idx + 1) begin
            aer_x   = tile_idx * TILE_STEP + 16;
            aer_y   = TY_FIXED * TILE_STEP + 16;
            aer_req = 1'b1;
            repeat(DWELL_CYCLES) @(posedge clk);
            aer_req = 1'b0;
            ev_cycles = ev_cycles + DWELL_CYCLES;
            // brief gap between tiles (a few scan periods)
            repeat(512) @(posedge clk);
        end

        repeat(4096) @(posedge clk);

        $display("NAT_RESULT status=%s ev_cyc=%0d lif=%0d ds=%0d burst=%0d pred=%0d first_pred=%0d",
                 (pred_cnt > 0) ? "PASS" : "FAIL",
                 ev_cycles, lif_cnt, ds_cnt, burst_cnt, pred_cnt, first_pred_cyc);

        if (pred_cnt > 0)
            $display("PASS: naturalistic continuous injection works — pred_valid fired %0d times", pred_cnt);
        else
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
