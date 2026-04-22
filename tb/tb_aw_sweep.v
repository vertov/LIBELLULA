`timescale 1ns/1ps
`default_nettype none

// AW sweep bench: run the same constant-velocity East motion scenario
// for three different tile resolutions.
//
// For each AW configuration a separate DUT is instantiated with wrapper
// module aw_accuracy_dut (defined at the bottom of this file).
// Predictions and errors are collected per-DUT, then a summary table printed.
//
// AW sweep:
//   AW=6  -> 8x8 tile grid,  tile=128x128px, scan_period=64,  THRESH=16
//   AW=8  -> 16x16 grid,     tile=64x64px,   scan_period=256, THRESH=16
//   AW=10 -> 32x32 grid,     tile=32x32px,   scan_period=1024,THRESH=16
//
// The expected trade-off:
//   Lower AW: faster scan → lower dwell requirement, but coarser tiles → worse accuracy floor
//   Higher AW: finer tiles → better accuracy, but slower scan → higher minimum dwell
//
// All DUTs see identical events (same (aer_x, aer_y) sequence).
// Accuracy measured as |x_hat - true_x|.

module tb_aw_sweep;

    localparam XW = 10;
    localparam YW = 10;
    localparam DW = 0;
    localparam PW = 16;

    // Common motion parameters (scaled per AW below)
    localparam [3:0] START_TX  = 4'd2;
    localparam       NUM_STEPS = 8;
    localparam integer EV_OFFSET = 20;

    // Three AW values under test
    localparam AW6  = 6;
    localparam AW8  = 8;
    localparam AW10 = 10;

    // Tile sizes (pixels): 2^(XW - AW/2)
    localparam TILE6  = 1 << (XW - AW6/2);   // 128
    localparam TILE8  = 1 << (XW - AW8/2);   // 64
    localparam TILE10 = 1 << (XW - AW10/2);  // 32

    // Scan period = 2^AW cycles
    localparam SCAN6  = 1 << AW6;    // 64
    localparam SCAN8  = 1 << AW8;    // 256
    localparam SCAN10 = 1 << AW10;   // 1024

    localparam THRESH = 16;
    localparam HITS   = THRESH + 4;   // hits per tile

    // Fixed y-tile row for each AW
    localparam TY6  = 3;
    localparam TY8  = 4;
    localparam TY10 = 5;

    // -------------------------------------------------------------------------
    // Shared clock (all DUTs use the same clock)
    // -------------------------------------------------------------------------
    reg clk = 0;
    always #5 clk = ~clk;

    // Three independent reset / scan_addr / aer buses (driven by stimulus)
    reg  rst6=1,  rst8=1,  rst10=1;
    reg  req6=0,  req8=0,  req10=0;
    reg  [XW-1:0] ax6=0,  ax8=0,  ax10=0;
    reg  [YW-1:0] ay6=0,  ay8=0,  ay10=0;
    reg  [AW6-1:0]  sa6  = 0;
    reg  [AW8-1:0]  sa8  = 0;
    reg  [AW10-1:0] sa10 = 0;

    // Predictor outputs
    wire pv6,  pv8,  pv10;
    wire [PW-1:0] xh6, xh8, xh10;
    wire [PW-1:0] yh6, yh8, yh10;
    wire [7:0]  cf6, cf8, cf10;
    wire cov6, cov8, cov10;
    wire [1:0] tid6, tid8, tid10;

    // Scan counters
    always @(posedge clk) if (rst6)  sa6  <= 0; else sa6  <= sa6  + 1'b1;
    always @(posedge clk) if (rst8)  sa8  <= 0; else sa8  <= sa8  + 1'b1;
    always @(posedge clk) if (rst10) sa10 <= 0; else sa10 <= sa10 + 1'b1;

    // -------------------------------------------------------------------------
    // DUT instances: one per AW
    // -------------------------------------------------------------------------
    libellula_top #(.XW(XW),.YW(YW),.AW(AW6), .DW(DW),.PW(PW),.TILE_STEP(1)) dut6 (
        .clk(clk),.rst(rst6),.aer_req(req6),.aer_ack(),
        .aer_x(ax6),.aer_y(ay6),.aer_pol(1'b1),.scan_addr(sa6),
        .pred_valid(pv6),.x_hat(xh6),.y_hat(yh6),
        .conf(cf6),.conf_valid(cov6),.track_id(tid6));

    libellula_top #(.XW(XW),.YW(YW),.AW(AW8), .DW(DW),.PW(PW),.TILE_STEP(1)) dut8 (
        .clk(clk),.rst(rst8),.aer_req(req8),.aer_ack(),
        .aer_x(ax8),.aer_y(ay8),.aer_pol(1'b1),.scan_addr(sa8),
        .pred_valid(pv8),.x_hat(xh8),.y_hat(yh8),
        .conf(cf8),.conf_valid(cov8),.track_id(tid8));

    libellula_top #(.XW(XW),.YW(YW),.AW(AW10),.DW(DW),.PW(PW),.TILE_STEP(1)) dut10 (
        .clk(clk),.rst(rst10),.aer_req(req10),.aer_ack(),
        .aer_x(ax10),.aer_y(ay10),.aer_pol(1'b1),.scan_addr(sa10),
        .pred_valid(pv10),.x_hat(xh10),.y_hat(yh10),
        .conf(cf10),.conf_valid(cov10),.track_id(tid10));

    // -------------------------------------------------------------------------
    // Per-DUT accuracy accumulators
    // -------------------------------------------------------------------------
    integer pc6=0,  pc8=0,  pc10=0;
    integer es6=0,  es8=0,  es10=0;
    integer em6=0,  em8=0,  em10=0;
    integer tx6=0,  tx8=0,  tx10=0;  // true_x set by stimulus
    integer ae;

    always @(posedge clk) begin
        if (!rst6 && pv6) begin
            ae = (xh6 >= tx6) ? (xh6 - tx6) : (tx6 - xh6);
            pc6 <= pc6+1; es6 <= es6+ae; if(ae>em6) em6 <= ae;
            $display("AW6  CYC=%0d x=%0d true=%0d err=%0d", $time/10, xh6, tx6, ae);
        end
        if (!rst8 && pv8) begin
            ae = (xh8 >= tx8) ? (xh8 - tx8) : (tx8 - xh8);
            pc8 <= pc8+1; es8 <= es8+ae; if(ae>em8) em8 <= ae;
            $display("AW8  CYC=%0d x=%0d true=%0d err=%0d", $time/10, xh8, tx8, ae);
        end
        if (!rst10 && pv10) begin
            ae = (xh10 >= tx10) ? (xh10 - tx10) : (tx10 - xh10);
            pc10 <= pc10+1; es10 <= es10+ae; if(ae>em10) em10 <= ae;
            $display("AW10 CYC=%0d x=%0d true=%0d err=%0d", $time/10, xh10, tx10, ae);
        end
    end

    // -------------------------------------------------------------------------
    // Scan-sync injection helpers (one per AW: different scan_addr width)
    // -------------------------------------------------------------------------
    // AW=6 helper
    task hit6;
        input [AW6-1:0] na; input [XW-1:0] ex; input [YW-1:0] ey;
        begin
            @(negedge clk); ax6=ex; ay6=ey; req6=1'b1;
            while (sa6 !== na) @(posedge clk);
            @(negedge clk); req6=1'b0;
        end
    endtask

    // AW=8 helper
    task hit8;
        input [AW8-1:0] na; input [XW-1:0] ex; input [YW-1:0] ey;
        begin
            @(negedge clk); ax8=ex; ay8=ey; req8=1'b1;
            while (sa8 !== na) @(posedge clk);
            @(negedge clk); req8=1'b0;
        end
    endtask

    // AW=10 helper
    task hit10;
        input [AW10-1:0] na; input [XW-1:0] ex; input [YW-1:0] ey;
        begin
            @(negedge clk); ax10=ex; ay10=ey; req10=1'b1;
            while (sa10 !== na) @(posedge clk);
            @(negedge clk); req10=1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Tile address helpers per AW
    // -------------------------------------------------------------------------
    function [AW6-1:0] taddr6;
        input [3:0] tx; input [3:0] ty;
        begin
            // HX6 = AW6/2 = 3, HY6 = AW6-HX6 = 3
            taddr6 = {tx[2:0], ty[2:0]};
        end
    endfunction

    function [AW8-1:0] taddr8;
        input [3:0] tx; input [3:0] ty;
        begin
            // HX8 = 4, HY8 = 4
            taddr8 = {tx[3:0], ty[3:0]};
        end
    endfunction

    function [AW10-1:0] taddr10;
        input [4:0] tx; input [4:0] ty;
        begin
            // HX10 = 5, HY10 = 5
            taddr10 = {tx[4:0], ty[4:0]};
        end
    endfunction

    // -------------------------------------------------------------------------
    // Stimulus: run all three DUTs in parallel (same clock, independent events)
    // -------------------------------------------------------------------------
    integer step, h;
    // Intermediate tile-index variables (avoid part-select on integer expressions)
    reg [3:0]  cur_tx4;
    reg [4:0]  cur_tx5;

    initial begin
        // Release resets with a small offset to desync scan_addr counters
        repeat(20) @(posedge clk);
        rst6 = 0; rst8 = 0; rst10 = 0;
        repeat(5) @(posedge clk);

        for (step = 0; step < NUM_STEPS; step = step + 1) begin
            // True pixel position for this step
            tx6  = (START_TX + step) * TILE6  + EV_OFFSET;
            tx8  = (START_TX + step) * TILE8  + EV_OFFSET;
            tx10 = (START_TX + step) * TILE10 + EV_OFFSET;
            cur_tx4 = START_TX + step;
            cur_tx5 = START_TX + step;

            // Inject hits for AW=6
            for (h = 0; h < HITS; h = h + 1) begin
                hit6(taddr6(cur_tx4, TY6),
                     (START_TX+step) * TILE6 + EV_OFFSET,
                     TY6 * TILE6 + EV_OFFSET);
                @(posedge clk);
            end

            // Inject hits for AW=8
            for (h = 0; h < HITS; h = h + 1) begin
                hit8(taddr8(cur_tx4, TY8),
                     (START_TX+step) * TILE8 + EV_OFFSET,
                     TY8 * TILE8 + EV_OFFSET);
                @(posedge clk);
            end

            // Inject hits for AW=10
            for (h = 0; h < HITS; h = h + 1) begin
                hit10(taddr10(cur_tx5, TY10),
                      (START_TX+step) * TILE10 + EV_OFFSET,
                      TY10 * TILE10 + EV_OFFSET);
                @(posedge clk);
            end

            repeat(SCAN10 * 2) @(posedge clk);  // drain long enough for AW=10
        end

        repeat(SCAN10 * 4) @(posedge clk);

        // Summary
        $display("");
        $display("AW_SWEEP_SUMMARY");
        $display("| AW | tile_px | scan_cyc | min_dwell_cyc | preds | mean_err_x | max_err_x |");
        $display("|----+---------+----------+---------------+-------+------------+-----------|");
        if (pc6 > 0)
            $display("| 6  | %7d | %8d | %13d | %5d | %10d | %9d |",
                TILE6, SCAN6, THRESH*SCAN6, pc6, es6/pc6, em6);
        else
            $display("| 6  | %7d | %8d | %13d |     0 |          - |         - |",
                TILE6, SCAN6, THRESH*SCAN6);

        if (pc8 > 0)
            $display("| 8  | %7d | %8d | %13d | %5d | %10d | %9d |",
                TILE8, SCAN8, THRESH*SCAN8, pc8, es8/pc8, em8);
        else
            $display("| 8  | %7d | %8d | %13d |     0 |          - |         - |",
                TILE8, SCAN8, THRESH*SCAN8);

        if (pc10 > 0)
            $display("| 10 | %7d | %8d | %13d | %5d | %10d | %9d |",
                TILE10, SCAN10, THRESH*SCAN10, pc10, es10/pc10, em10);
        else
            $display("| 10 | %7d | %8d | %13d |     0 |          - |         - |",
                TILE10, SCAN10, THRESH*SCAN10);

        $display("");
        $display("AW_SWEEP_STATUS preds6=%0d preds8=%0d preds10=%0d", pc6, pc8, pc10);
        if (pc6 > 0 && pc8 > 0 && pc10 > 0)
            $display("AW_SWEEP_PASS: all three AW values produced predictions");
        else
            $display("AW_SWEEP_PARTIAL: some AW values did not produce predictions");

        $finish;
    end

    initial begin #5000000000; $display("TIMEOUT"); $finish; end

endmodule

`default_nettype wire
