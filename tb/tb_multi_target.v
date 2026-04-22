`timescale 1ns/1ps
`default_nettype none

// Multi-target bench.
// Two targets on different y-tile rows, both moving East at the same velocity.
// Target A: tile_y=6, tile_x=2..9
// Target B: tile_y=10, tile_x=2..9
//
// The single-state ab_predictor cannot independently track both targets.
// This bench documents what actually happens: averaging, oscillation, or deadlock.
//
// Injection: alternating scan-sync hits — A hit, then B hit, per tile position.
// Both targets advance together (same tile step per round).
//
// Metrics:
//   - Does pred_valid fire?
//   - Does x_hat converge? (both targets have same x so x may be accurate)
//   - Does y_hat oscillate between the two target y-rows?
//   - What is the y_hat error relative to each target?

module tb_multi_target;

    localparam XW=10, YW=10, AW=8, DW=0, PW=16, HX=4, TILE_STEP=1;
    localparam THRESH    = 16;
    localparam HITS_TILE = THRESH + 4;
    localparam TYA       = 4'd6;
    localparam TYB       = 4'd10;
    localparam START_TX  = 4'd2;
    localparam NUM_TILES = 8;
    localparam DWELL_PAD = 512;

    localparam TRUE_YA = TYA * 64 + 16;
    localparam TRUE_YB = TYB * 64 + 16;

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

    integer cyc=0, pred_cnt=0;
    integer true_x_now=0;
    integer err_ya_sum=0, err_yb_sum=0, err_ya_max=0, err_yb_max=0;
    integer err_x_sum=0, err_x_max=0;
    integer abs_ya, abs_yb, abs_x;

    always @(posedge clk) begin
        if(!rst) cyc<=cyc+1;
        if(!rst && pred_valid) begin
            abs_ya = (y_hat >= TRUE_YA) ? (y_hat-TRUE_YA) : (TRUE_YA-y_hat);
            abs_yb = (y_hat >= TRUE_YB) ? (y_hat-TRUE_YB) : (TRUE_YB-y_hat);
            abs_x  = (x_hat >= true_x_now) ? (x_hat-true_x_now) : (true_x_now-x_hat);
            pred_cnt <= pred_cnt+1;
            err_ya_sum <= err_ya_sum + abs_ya;
            err_yb_sum <= err_yb_sum + abs_yb;
            err_x_sum  <= err_x_sum + abs_x;
            if(abs_ya > err_ya_max) err_ya_max <= abs_ya;
            if(abs_yb > err_yb_max) err_yb_max <= abs_yb;
            if(abs_x  > err_x_max)  err_x_max  <= abs_x;
            $display("CYC=%0d PRED x=%0d y=%0d  err_x=%0d err_ya=%0d err_yb=%0d",
                     cyc, x_hat, y_hat, abs_x, abs_ya, abs_yb);
        end
    end

    integer ti, h;

    initial begin
        repeat(20) @(posedge clk); rst=0; repeat(5) @(posedge clk);

        for(ti=START_TX; ti<START_TX+NUM_TILES; ti=ti+1) begin
            true_x_now = ti*64+16;
            for(h=0; h<HITS_TILE; h=h+1) begin
                scan_hit(taddr(ti[3:0],TYA), ti[XW-1:0]*64+16, TYA*64+16);
                @(posedge clk);
                scan_hit(taddr(ti[3:0],TYB), ti[XW-1:0]*64+16, TYB*64+16);
                @(posedge clk);
            end
            repeat(DWELL_PAD) @(posedge clk);
        end
        repeat(4096) @(posedge clk);

        $display("MULTI_RESULT preds=%0d", pred_cnt);
        if(pred_cnt > 0) begin
            $display("MULTI_X   mean_err=%0d max_err=%0d",
                     err_x_sum/pred_cnt, err_x_max);
            $display("MULTI_Y_A mean_err_vs_A=%0d max=%0d  (true_yA=%0d)",
                     err_ya_sum/pred_cnt, err_ya_max, TRUE_YA);
            $display("MULTI_Y_B mean_err_vs_B=%0d max=%0d  (true_yB=%0d)",
                     err_yb_sum/pred_cnt, err_yb_max, TRUE_YB);
            $display("MULTI_SEPARATION target_sep_px=%0d", TRUE_YB-TRUE_YA);
            if(err_ya_max <= 32)
                $display("MULTI_VERDICT locked to target A");
            else if(err_yb_max <= 32)
                $display("MULTI_VERDICT locked to target B");
            else
                $display("MULTI_VERDICT averaging/oscillating — single tracker insufficient for 2 targets");
        end
        $finish;
    end

    initial begin #3000000000; $display("TIMEOUT"); $finish; end
endmodule

`default_nettype wire
