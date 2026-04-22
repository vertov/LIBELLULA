`timescale 1ns/1ps
`default_nettype none

// tb_ego_motion_rejection: Uniform background / ego-motion scenario.
// Inject events spread across 16 distinct tiles, THRESH-1=15 events each.
// No tile reaches THRESH=16 → no LIF spikes → no Reichardt output → pred_valid=0.
// Asserts: pred_valid never fires during or after the entire stimulus.

`include "tb_common_tasks.vh"
module tb_ego_motion_rejection;
    localparam T_NS = 5;
    localparam XW=10, YW=10, AW=8, DW=0, PW=16;
    localparam THRESH = 16;
    localparam PER_TILE = THRESH - 1; // 15 events: just below threshold

    reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

    reg aer_req=0; wire aer_ack;
    reg [XW-1:0] aer_x=0; reg [YW-1:0] aer_y=0; reg aer_pol=0;
    reg [AW-1:0] scan=0; always @(posedge clk) if (!rst) scan<=scan+1'b1;

    wire pred_valid; wire [PW-1:0] x_hat,y_hat; wire [7:0] conf; wire conf_valid;
    wire [1:0] tid_unused;
    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW)) dut(
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid),.x_hat(x_hat),.y_hat(y_hat),
        .conf(conf),.conf_valid(conf_valid),.track_id(tid_unused)
    );

    // 16 tile centres: tile_x in {0..3}, tile_y in {0..3}
    // tile centre x = tile_x*64 + 10, y = tile_y*64 + 10
    integer tile, ev, pred_count=0;
    integer tx_coord, ty_coord;

    always @(posedge clk)
        if (pred_valid) pred_count <= pred_count + 1;

    initial begin
        #(20*T_NS) rst=0;

        for (tile=0; tile<16; tile=tile+1) begin
            tx_coord = (tile % 4) * 64 + 10;
            ty_coord = (tile / 4) * 64 + 10;
            for (ev=0; ev<PER_TILE; ev=ev+1) begin
                @(negedge clk);
                aer_x <= tx_coord[XW-1:0];
                aer_y <= ty_coord[YW-1:0];
                aer_req <= 1;
                @(negedge clk); aer_req<=0;
                @(negedge clk);
            end
        end
        repeat(30) @(negedge clk);

        $display("EGO_MOTION: tiles=16 events_per_tile=%0d pred_count=%0d",
                 PER_TILE, pred_count);
        if (pred_count > 0)
            fail_msg("pred_valid fired under uniform ego-motion (each tile <THRESH)");
        pass();
    end
endmodule
`default_nettype wire
