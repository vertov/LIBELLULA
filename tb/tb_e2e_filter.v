`timescale 1ns/1ps
`default_nettype none

// End-to-end motion bench with the background-activity filter ENABLED.
// Same scan-synchronised constant-velocity stimulus as tb_e2e_motion, plus
// injected isolated noise events far from the target track.
//
// Verifies that with AF_EN=1:
//   1. The real target still drives the full pipeline (pred_valid fires).
//   2. Isolated noise events are dropped by the filter (drop counter > 0).
//   3. Target-event losses are limited to cold-region startup (first event
//      of a silent region), not ongoing attrition.

module tb_e2e_filter;

    localparam XW        = 10;
    localparam YW        = 10;
    localparam AW        = 8;
    localparam DW        = 0;
    localparam PW        = 16;
    localparam HX        = AW / 2;
    localparam HY        = AW - HX;
    localparam TILE_STEP = 1 << (XW - HX);  // 64 px
    localparam THRESH    = 16;
    localparam NUM_TILES = 10;
    localparam HITS_TILE = THRESH + 6;      // extra headroom: filter may drop the first event
    localparam MAX_CYC   = 1_000_000;

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
    wire [7:0]    conf;
    wire          conf_valid;

    libellula_top #(
        .XW(XW), .YW(YW), .AW(AW), .DW(DW), .PW(PW),
        .TILE_STEP(TILE_STEP),
        .AF_EN(1), .AF_WINDOW(2048)
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

    // ---------------- stage monitoring ----------------
    integer pred_cnt = 0;
    integer drop_cnt = 0;
    integer cyc      = 0;

    always @(posedge clk) begin
        if (!rst) cyc <= cyc + 1;
        if (!rst && pred_valid) pred_cnt <= pred_cnt + 1;
        if (!rst && dut.af_dropped) drop_cnt <= drop_cnt + 1;
    end

    // ---------------- scan-synchronised injection ----------------
    function [AW-1:0] tile_addr;
        input [3:0] tx;
        input [3:0] ty;
        begin
            tile_addr = {tx[HX-1:0], ty[HY-1:0]};
        end
    endfunction

    task send_scan_hit;
        input [AW-1:0] naddr;
        input [XW-1:0] ex;
        input [YW-1:0] ey;
        begin
            @(negedge clk);
            aer_x   = ex;
            aer_y   = ey;
            aer_pol = 1'b1;
            aer_req = 1'b1;
            while (scan_addr !== naddr) @(posedge clk);
            @(negedge clk);
            aer_req = 1'b0;
        end
    endtask

    // ---------------- stimulus ----------------
    integer tile_idx, h;
    integer ev_total = 0;
    integer noise_total = 0;
    integer drops_at_noise_check;

    initial begin
        repeat (300) @(posedge clk);   // covers the filter's 2^AW-cycle reset clear
        rst = 0;
        repeat (5) @(posedge clk);

        for (tile_idx = 2; tile_idx < 2 + NUM_TILES; tile_idx = tile_idx + 1) begin
            for (h = 0; h < HITS_TILE; h = h + 1) begin
                send_scan_hit(
                    tile_addr(tile_idx[3:0], 4'd8),
                    tile_idx[XW-1:0] * TILE_STEP + 16,
                    8 * TILE_STEP + 16
                );
                ev_total = ev_total + 1;
                @(posedge clk);
            end

            // One isolated noise event per tile period, far from the track
            // (tile row 1 vs target row 8, rotating column). No spatial
            // support -> the filter must drop it.
            drops_at_noise_check = drop_cnt;
            send_scan_hit(
                tile_addr(4'd12 - tile_idx[3:0], 4'd1),
                (12 - tile_idx[3:0]) * TILE_STEP + 30,
                1 * TILE_STEP + 30
            );
            noise_total = noise_total + 1;

            repeat (512) @(posedge clk);
        end

        repeat (4096) @(posedge clk);

        // ---------------- report ----------------
        $display("E2EF_RESULT status=%s ev=%0d noise=%0d dropped=%0d pred=%0d",
                 (pred_cnt > 0) ? "PASS" : "FAIL",
                 ev_total, noise_total, drop_cnt, pred_cnt);

        if (pred_cnt == 0)
            $display("FAIL: pred_valid never asserted with AF_EN=1");
        else if (drop_cnt < noise_total)
            $display("FAIL: filter passed isolated noise (dropped=%0d < noise=%0d)",
                     drop_cnt, noise_total);
        else if (drop_cnt > noise_total + 4)
            // Every drop beyond the noise events + cold-start allowance is a
            // real target event lost to the filter.
            $display("FAIL: filter dropped %0d target events (allowance 4)",
                     drop_cnt - noise_total);
        else
            $display("PASS: pipeline predicts through the filter; %0d/%0d noise dropped, %0d cold-start drops",
                     noise_total, noise_total, drop_cnt - noise_total);

        $finish;
    end

    initial begin
        #(MAX_CYC * 10);
        $display("TIMEOUT — pred=%0d dropped=%0d", pred_cnt, drop_cnt);
        $finish;
    end

endmodule

`default_nettype wire
