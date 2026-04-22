`timescale 1ns/1ps
`default_nettype none

// Clutter rejection bench.
// Signal: single moving target, scan-synchronised hits, 6 tiles East.
// Clutter: random events at uniformly-distributed (x,y) coordinates,
//          injected at rate 1 event per CLUTTER_INTERVAL cycles using an LFSR.
// Sweep: CLUTTER_INTERVAL = {none, 512, 256, 128, 64} cycles between noise events.
//
// Success criterion at each SNR level:
//   - pred_valid fires (tracker stays locked)
//   - pred count >= MIN_PREDS (not dominated by false positives)
//   - mean x_hat error remains <= MAX_ERR pixels
//
// The burst gate (WINDOW=1024, TH_OPEN=2) is the primary clutter rejection mechanism.
// Clutter must produce 2 events in 1024 cycles from the SAME Reichardt correlation
// to open the gate — random events with random spatial positions will rarely satisfy
// the consecutive-tile correlation required by the delay lattice.

module tb_clutter;

    localparam XW=10, YW=10, AW=8, DW=0, PW=16, HX=4, TILE_STEP=1;
    localparam THRESH    = 16;
    localparam HITS_TILE = THRESH + 2;  // 18 scan-sync hits per tile
    localparam NUM_TILES = 6;
    localparam TY        = 4'd7;
    localparam START_TX  = 4'd3;
    localparam MIN_PREDS = 3;
    localparam MAX_ERR   = 64;  // 1 tile tolerance (warm-up lag)

    localparam NUM_SNR = 5;
    integer CLT_INT[0:4];   // clutter interval in cycles
    initial begin
        CLT_INT[0] = 0;     // no clutter (baseline)
        CLT_INT[1] = 512;   // low clutter
        CLT_INT[2] = 256;   // moderate
        CLT_INT[3] = 128;   // high clutter (1 event per half-scan-period)
        CLT_INT[4] = 64;    // very high
    end

    reg clk=0; always #5 clk=~clk;
    reg  rst=1, aer_req=0; wire aer_ack;
    reg  [XW-1:0] aer_x=0; reg [YW-1:0] aer_y=0; reg aer_pol=0;
    reg  [AW-1:0] scan_addr=0;
    wire pred_valid; wire [PW-1:0] x_hat, y_hat;
    wire [7:0] conf; wire conf_valid;
    wire lif_v = dut.lif_v;

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

    // LFSR for pseudo-random clutter coordinates
    reg [19:0] lfsr_x = 20'hABCDE;
    reg [19:0] lfsr_y = 20'h12345;
    wire lfsr_fb_x = lfsr_x[19]^lfsr_x[16];
    wire lfsr_fb_y = lfsr_y[19]^lfsr_y[16];

    // Clutter injection (concurrent with signal, driven from separate thread)
    reg clutter_en = 0;
    integer clutter_interval = 0;
    integer clutter_timer = 0;
    integer clutter_count = 0;

    always @(posedge clk) begin
        lfsr_x <= {lfsr_x[18:0], lfsr_fb_x};
        lfsr_y <= {lfsr_y[18:0], lfsr_fb_y};
        if(rst || !clutter_en) begin
            clutter_timer <= 0; clutter_count <= 0;
        end else if(clutter_interval > 0) begin
            if(clutter_timer == 0) begin
                // Inject a random-coord event (1 cycle pulse)
                // Only if the signal is not currently driving aer_req
                if(!aer_req) begin
                    // We can't drive aer_req from two always blocks safely in Verilog.
                    // Clutter is modeled through the LIF noise accumulation path:
                    // We count how many clutter events would hit the target neuron address.
                    // Actual injection handled in the task below via aer_req arbitration.
                    clutter_count <= clutter_count + 1;
                end
                clutter_timer <= clutter_interval - 1;
            end else
                clutter_timer <= clutter_timer - 1;
        end
    end

    // Per-run counters
    integer pred_cnt_snap = 0;
    integer err_sum_snap  = 0;
    integer err_max_snap  = 0;
    integer true_x_global = 0;
    integer abs_ex;

    always @(posedge clk) begin
        if(rst) begin pred_cnt_snap<=0; err_sum_snap<=0; err_max_snap<=0; end
        else if(pred_valid) begin
            abs_ex = (x_hat >= true_x_global) ? (x_hat - true_x_global) : (true_x_global - x_hat);
            pred_cnt_snap <= pred_cnt_snap + 1;
            err_sum_snap  <= err_sum_snap + abs_ex;
            if(abs_ex > err_max_snap) err_max_snap <= abs_ex;
        end
    end

    // Signal injection task with interleaved clutter
    task run_with_clutter;
        input integer clt_int;
        output integer preds;
        output integer mean_err;
        output integer max_err;
        integer ti, h, gap, clt_timer;
        reg [XW-1:0] cx; reg [YW-1:0] cy;
        begin
            @(negedge clk); rst=1; aer_req=0;
            repeat(20) @(posedge clk); rst=0;
            repeat(5) @(posedge clk);
            clt_timer = clt_int;

            for(ti=START_TX; ti<START_TX+NUM_TILES; ti=ti+1) begin
                true_x_global = ti*64+16;
                for(h=0; h<HITS_TILE; h=h+1) begin
                    // Signal hit
                    scan_hit(taddr(ti[3:0],TY), ti[XW-1:0]*64+16, TY*64+16);
                    @(posedge clk);
                    // Interleave clutter events in the gaps between signal hits
                    if(clt_int > 0) begin
                        clt_timer = clt_timer - HITS_TILE;
                        if(clt_timer <= 0) begin
                            clt_timer = clt_int;
                            // Inject one random clutter event
                            @(negedge clk);
                            aer_x = lfsr_x[9:0];
                            aer_y = lfsr_y[9:0];
                            aer_pol = 0;
                            aer_req = 1;
                            @(posedge clk);
                            @(negedge clk);
                            aer_req = 0;
                        end
                    end
                end
                repeat(512) @(posedge clk);
            end
            repeat(2048) @(posedge clk);
            preds    = pred_cnt_snap;
            mean_err = (pred_cnt_snap > 0) ? (err_sum_snap / pred_cnt_snap) : 9999;
            max_err  = err_max_snap;
        end
    endtask

    integer run_idx, out_preds, out_mean, out_max;
    integer clt_int_val;

    initial begin
        $display("CLT_HEADER clutter_interval approx_snr_ratio pred_cnt mean_err max_err status");
        for(run_idx=0; run_idx<NUM_SNR; run_idx=run_idx+1) begin
            clt_int_val = CLT_INT[run_idx];
            // Reset snap counters before each run
            @(negedge clk); rst=1;
            repeat(5) @(posedge clk); rst=0;
            pred_cnt_snap=0; err_sum_snap=0; err_max_snap=0;
            run_with_clutter(clt_int_val, out_preds, out_mean, out_max);
            $display("CLT_ROW clt_int=%0d pred=%0d mean_err=%0d max_err=%0d status=%s",
                     clt_int_val, out_preds, out_mean, out_max,
                     (out_preds >= MIN_PREDS && out_max <= MAX_ERR) ? "PASS" : "FAIL");
        end
        $display("CLT_DONE");
        $finish;
    end

    initial begin #1000000000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
