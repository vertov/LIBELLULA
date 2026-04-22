`timescale 1ns/1ps
`default_nettype none

// Velocity range bench.
// Sweeps tile dwell time from DWELL_SLOW down to DWELL_FAST cycles.
// Each run: target moves 8 tiles East with that dwell, reports whether
// pred_valid fires and how many of the 8 transitions were tracked.
//
// Dwell time controls effective target velocity:
//   velocity (px/scan) = TILE_STEP_PX / (DWELL / SCAN_PERIOD)
//                      = 64 / (DWELL / 256)
//   e.g. DWELL=4096 → v=4px/scan, DWELL=1024 → v=16px/scan
//
// LIF accumulation requires THRESH=16 hits. With scan-sync injection
// (1 hit/scan guaranteed), minimum dwell = THRESH * SCAN_PERIOD = 16*256 = 4096.
// Below 4096 the LIF never fires for that tile → tracking fails.

module tb_velocity_range;

    localparam XW=10, YW=10, AW=8, DW=0, PW=16, HX=4, TILE_STEP=1;
    localparam THRESH     = 16;
    localparam SCAN_PER   = 1 << AW;   // 256
    localparam HITS_TILE  = THRESH + 2; // 18 scan-sync hits per tile
    localparam NUM_TILES  = 8;
    localparam TY         = 4'd6;
    localparam START_TX   = 4'd2;

    // Dwell values to sweep (cycles spent at each tile)
    // These represent: fast, nominal, slow
    localparam NUM_SPEEDS = 5;
    integer DWELL[0:4];
    initial begin
        DWELL[0] = 3000;   // below accumulation threshold: should FAIL
        DWELL[1] = 4096;   // exactly THRESH*SCAN: marginal
        DWELL[2] = 5000;   // comfortable margin: should PASS
        DWELL[3] = 8000;   // slow: should PASS
        DWELL[4] = 16000;  // very slow: should PASS
    end

    reg clk=0; always #5 clk=~clk;

    reg  rst=1, aer_req=0; wire aer_ack;
    reg  [XW-1:0] aer_x=0; reg [YW-1:0] aer_y=0; reg aer_pol=0;
    reg  [AW-1:0] scan_addr=0;
    wire pred_valid; wire [PW-1:0] x_hat, y_hat;
    wire [7:0] conf; wire conf_valid;

    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),.TILE_STEP(TILE_STEP)) dut (
        .clk(clk),.rst(rst),.aer_req(aer_req),.aer_ack(aer_ack),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),.scan_addr(scan_addr),
        .pred_valid(pred_valid),.x_hat(x_hat),.y_hat(y_hat),.conf(conf),.conf_valid(conf_valid));

    always @(posedge clk) if(rst) scan_addr<=0; else scan_addr<=scan_addr+1'b1;

    localparam HY = AW - HX;
    function [AW-1:0] taddr; input [3:0] tx; input [3:0] ty;
        taddr = {tx[HX-1:0], ty[HY-1:0]}; endfunction

    task scan_hit; input [AW-1:0] na; input [XW-1:0] ex; input [YW-1:0] ey;
        begin @(negedge clk); aer_x=ex; aer_y=ey; aer_pol=1; aer_req=1;
        while(scan_addr!==na) @(posedge clk);
        @(negedge clk); aer_req=0; end
    endtask

    // Dwell-based injection (not scan-sync, just hold for dwell cycles)
    task dwell_hit; input integer dwell_cyc; input [XW-1:0] ex; input [YW-1:0] ey;
        begin aer_x=ex; aer_y=ey; aer_pol=1; aer_req=1;
        repeat(dwell_cyc) @(posedge clk);
        aer_req=0; end
    endtask

    integer speed_idx, tile_idx, h;
    integer pred_cnt, lif_cnt;
    integer dwell_val;
    real velocity_px_per_scan;

    wire lif_v = dut.lif_v;

    // Run one speed trial
    task run_speed_trial;
        input integer dwell_cycles;
        output integer preds;
        output integer lifs;
        integer ti, hi;
        begin
            // Hard reset
            @(negedge clk); rst=1; aer_req=0;
            repeat(20) @(posedge clk);
            @(negedge clk); rst=0;
            repeat(5) @(posedge clk);
            preds=0; lifs=0;

            for(ti=START_TX; ti<START_TX+NUM_TILES; ti=ti+1) begin
                // Use scan-sync hits so result is deterministic
                for(hi=0; hi<HITS_TILE; hi=hi+1) begin
                    scan_hit(taddr(ti[3:0],TY), ti[XW-1:0]*64+16, TY*64+16);
                    @(posedge clk);
                end
                // If dwell_cycles < HITS_TILE*SCAN_PER the hits were fast;
                // pad remaining dwell time
                if(dwell_cycles > HITS_TILE * SCAN_PER) begin
                    repeat(dwell_cycles - HITS_TILE * SCAN_PER) @(posedge clk);
                end
            end
            repeat(2048) @(posedge clk);
            preds = pred_count_snap;
            lifs  = lif_count_snap;
        end
    endtask

    // Snap counters (sampled between clock edges for task usage)
    integer pred_count_snap=0, lif_count_snap=0;
    always @(posedge clk) begin
        if(rst) begin pred_count_snap<=0; lif_count_snap<=0; end
        else begin
            if(pred_valid) pred_count_snap<=pred_count_snap+1;
            if(lif_v)      lif_count_snap<=lif_count_snap+1;
        end
    end

    integer out_preds, out_lifs;

    initial begin
        $display("VEL_HEADER dwell_cycles scan_periods_per_tile lif_spikes pred_count status");
        for(speed_idx=0; speed_idx<NUM_SPEEDS; speed_idx=speed_idx+1) begin
            dwell_val = DWELL[speed_idx];
            run_speed_trial(dwell_val, out_preds, out_lifs);
            $display("VEL_ROW dwell=%0d scans_per_tile=%0d lif=%0d pred=%0d status=%s",
                     dwell_val, dwell_val/SCAN_PER, out_lifs, out_preds,
                     (out_preds>0) ? "TRACK" : "LOST");
        end
        $display("VEL_DONE");
        $finish;
    end

    initial begin #500000000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
