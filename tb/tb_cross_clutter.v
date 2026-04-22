`timescale 1ns/1ps
`default_nettype none

`include "tb_common_tasks.vh"
module tb_cross_clutter;
    localparam T_NS=10;
    localparam XW=10, YW=10, AW=8, DW=4, PW=16;
    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=5; reg [YW-1:0] aer_y=10; reg aer_pol=0;
    reg [AW-1:0] scan=0; always @(posedge clk) if (!rst) scan<=scan+1'b1;

    wire pred_valid; wire [PW-1:0] x_hat,y_hat; wire [7:0] conf; wire conf_valid;
    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW)) dut(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack),.aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid),.x_hat(x_hat),.y_hat(y_hat),.conf(conf),.conf_valid(conf_valid)
    );

    integer t; integer mae_lib=0, mae_base=0; integer b_have=0; integer b_x=0,b_y=0;
    reg [XW-1:0] cx, cx2;
    reg [YW-1:0] cy, cy2;

    // Dedicated truth registers updated only when we send a target event.
    // aer_x/aer_y may hold clutter coordinates during fork blocks, so we
    // cannot use them as ground-truth in the posedge always block.
    reg [XW-1:0] tgt_x = 5;
    reg [YW-1:0] tgt_y = 10;

    initial begin
        #(20*T_NS) rst=0;
        for (t=0;t<80;t=t+1) begin
            @(negedge clk);
            // Update target truth before driving the bus (blocking assignments).
            tgt_x = tgt_x + 1;
            tgt_y = (t < 40) ? 10 : 11;
            aer_x <= tgt_x; aer_y <= tgt_y; aer_req<=1;
            @(negedge clk); aer_req<=0;

            // Clutter spread across 8 independent tiles so each tile receives
            // at most 80/8 = 10 events, which is below THRESH=16 → no LIF spikes.
            //
            // Tile mapping (AW=8, HX=4, HY=4 → 64-px tiles):
            //   clutter1 tile_x ∈ {3..10}, tile_y = 0  (cx in 192..832+, cy 2..8)
            //   clutter2 tile_x ∈ {3..10} offset by 4, tile_y = 2 (cy2 128..134)
            //
            // L∞ distance from target tiles (0,0)→(1,0):
            //   clutter1 tile (3,0): L∞ to (0,0)=3, to (1,0)=2 ✓ (≥2)
            //   clutter2 tile (3,2) / (7,2): L∞ to (0,0)=3, to (1,0)=2 ✓ (≥2)
            cx  = 192 + (t%8)*64 + (t%5);
            cy  = 2   + ((t*3)%7);
            cx2 = 192 + ((t+4)%8)*64 + (t%3);
            cy2 = 128 + ((t*5)%7);
            fork
                begin @(negedge clk);
                      aer_x<=cx; aer_y<=cy; aer_req<=1; @(negedge clk); aer_req<=0; end
                begin @(negedge clk);
                      aer_x<=cx2; aer_y<=cy2; aer_req<=1; @(negedge clk); aer_req<=0; end
            join
        end
        repeat (60) @(negedge clk);
        if (mae_lib > mae_base) fail_msg("MAE not < baseline under clutter");
        if (mae_lib > 400) fail_msg("Abs MAE too high under clutter");
        pass();
    end

    integer tx, ty, ex, ey, exb, eyb;
    always @(posedge clk) begin
        if (pred_valid) begin
            // Use dedicated target truth registers, not aer_x/aer_y which may
            // carry clutter coordinates when pred_valid fires.
            tx = tgt_x + 1; ty = tgt_y;
            ex = (x_hat>tx)?(x_hat-tx):(tx-x_hat);
            ey = (y_hat>ty)?(y_hat-ty):(ty-y_hat);
            mae_lib <= mae_lib+ex+ey;
            if (b_have) begin
                exb = (b_x>tx)?(b_x-tx):(tx-b_x);
                eyb = (b_y>ty)?(b_y-ty):(ty-b_y);
                mae_base <= mae_base+exb+eyb;
            end
            b_x <= tgt_x; b_y <= tgt_y; b_have <= 1;
        end
    end
endmodule

`default_nettype wire
