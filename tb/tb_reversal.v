`timescale 1ns/1ps
`default_nettype none

// Direction reversal bench.
// Phase 1: target moves East  6 tiles (tile_x = 3..8), then
// Phase 2: 1-tile pause (tile_x = 8, 2 extra dwell rounds),
// Phase 3: target moves West  6 tiles (tile_x = 8..3).
//
// Metrics:
//   - Does dir_x flip sign after reversal?
//   - Peak position error during reversal
//   - Cycles to re-lock after reversal
//
// Observation: if Reichardt direction hint is working (DW=0, correct signs),
// dir_x should be positive during East phase and negative during West phase.
// The predictor's velocity should adapt from +vx to -vx.

module tb_reversal;

    localparam XW=10, YW=10, AW=8, DW=0, PW=16, HX=4, TILE_STEP=1;
    localparam THRESH    = 16;
    localparam HITS_TILE = THRESH + 4;  // 20 hits/tile
    localparam TY        = 4'd8;
    localparam DWELL_PAD = 512;         // extra cycles between tile transitions

    reg clk=0; always #5 clk=~clk;
    reg  rst=1, aer_req=0; wire aer_ack;
    reg  [XW-1:0] aer_x=0; reg [YW-1:0] aer_y=0; reg aer_pol=0;
    reg  [AW-1:0] scan_addr=0;
    wire pred_valid; wire [PW-1:0] x_hat, y_hat;
    wire [7:0] conf; wire conf_valid;
    wire lif_v = dut.lif_v;
    wire signed [7:0] dir_x_rt = dut.dir_x;

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

    integer cyc=0, pred_cnt=0;
    integer true_x=0;
    integer east_preds=0, west_preds=0;
    integer east_err_sum=0, west_err_sum=0;
    integer east_err_max=0, west_err_max=0;
    integer abs_ex;
    integer phase=0;  // 0=east, 1=pause, 2=west
    integer dir_pos_cnt=0, dir_neg_cnt=0;
    integer reversal_detected_cyc=-1;
    integer relock_cyc=-1;

    always @(posedge clk) begin
        if(!rst) cyc <= cyc+1;
        if(!rst && dir_x_rt > 0) dir_pos_cnt <= dir_pos_cnt+1;
        if(!rst && dir_x_rt < 0) dir_neg_cnt <= dir_neg_cnt+1;
        if(!rst && pred_valid) begin
            abs_ex = (x_hat >= true_x) ? (x_hat - true_x) : (true_x - x_hat);
            pred_cnt <= pred_cnt + 1;
            $display("CYC=%0d PHASE=%0s PRED x_hat=%0d true_x=%0d err=%0d dir_x=%0d",
                     cyc,
                     (phase==0) ? "EAST" : (phase==1) ? "PAUSE" : "WEST",
                     x_hat, true_x, abs_ex, dir_x_rt);
            if(phase==0) begin
                east_preds <= east_preds+1;
                east_err_sum <= east_err_sum + abs_ex;
                if(abs_ex > east_err_max) east_err_max <= abs_ex;
            end else if(phase==2) begin
                west_preds <= west_preds+1;
                west_err_sum <= west_err_sum + abs_ex;
                if(abs_ex > west_err_max) west_err_max <= abs_ex;
                if(abs_ex <= 32 && relock_cyc < 0) relock_cyc <= cyc;
            end
        end
    end

    integer ti, h;

    initial begin
        repeat(20) @(posedge clk); rst=0; repeat(5) @(posedge clk);

        // -------- Phase 0: East (tile 3 → 8) --------
        phase = 0;
        for(ti=3; ti<=8; ti=ti+1) begin
            true_x = ti*64+16;
            for(h=0; h<HITS_TILE; h=h+1) begin
                scan_hit(taddr(ti[3:0],TY), ti[XW-1:0]*64+16, TY*64+16);
                @(posedge clk);
            end
            repeat(DWELL_PAD) @(posedge clk);
        end

        // -------- Phase 1: Pause at tile 8 --------
        phase = 1;
        repeat(2) begin
            for(h=0; h<HITS_TILE; h=h+1) begin
                scan_hit(taddr(4'd8,TY), 8*64+16, TY*64+16);
                @(posedge clk);
            end
            repeat(DWELL_PAD) @(posedge clk);
        end

        // -------- Phase 2: West (tile 7 → 2) --------
        phase = 2;
        for(ti=7; ti>=2; ti=ti-1) begin
            true_x = ti*64+16;
            for(h=0; h<HITS_TILE; h=h+1) begin
                scan_hit(taddr(ti[3:0],TY), ti[XW-1:0]*64+16, TY*64+16);
                @(posedge clk);
            end
            repeat(DWELL_PAD) @(posedge clk);
        end

        repeat(4096) @(posedge clk);

        // -------- Report --------
        $display("REV_EAST  preds=%0d mean_err=%0d max_err=%0d dir_pos_counts=%0d",
                 east_preds,
                 (east_preds>0) ? east_err_sum/east_preds : 9999,
                 east_err_max, dir_pos_cnt);
        $display("REV_WEST  preds=%0d mean_err=%0d max_err=%0d dir_neg_counts=%0d relock_cyc=%0d",
                 west_preds,
                 (west_preds>0) ? west_err_sum/west_preds : 9999,
                 west_err_max, dir_neg_cnt, relock_cyc);
        $display("REV_RESULT status=%s east_tracked=%s west_tracked=%s direction_detected=%s",
                 (east_preds>0 && west_preds>0) ? "PASS" : "FAIL",
                 (east_preds>0) ? "YES" : "NO",
                 (west_preds>0) ? "YES" : "NO",
                 (dir_neg_cnt>0) ? "YES" : "NO");
        $finish;
    end

    initial begin #3000000000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
