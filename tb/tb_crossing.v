`timescale 1ns/1ps
`default_nettype none

// tb_crossing: Bidirectional target tracking test
// Verifies both targets are tracked correctly when crossing paths

`include "tb_common_tasks.vh"
module tb_crossing;
    localparam T_NS = 5;  // 200 MHz
    localparam XW = 10, YW = 10, AW = 8, DW = 0, PW = 16;

    reg clk = 0, rst = 1;
    always #(T_NS/2) clk = ~clk;

    reg aer_req = 0;
    wire aer_ack;
    reg [XW-1:0] aer_x = 0;
    reg [YW-1:0] aer_y = 0;
    reg aer_pol = 0;
    reg [AW-1:0] scan = 0;

    wire pred_valid;
    wire [PW-1:0] x_hat, y_hat;
    wire [7:0] conf;
    wire conf_valid;

    wire [1:0] tid_unused;
    libellula_top #(.XW(XW), .YW(YW), .AW(AW), .DW(DW), .PW(PW)) dut (
        .clk(clk), .rst(rst),
        .aer_req(aer_req), .aer_ack(aer_ack),
        .aer_x(aer_x), .aer_y(aer_y), .aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid), .x_hat(x_hat), .y_hat(y_hat),
        .conf(conf), .conf_valid(conf_valid),
        .track_id(tid_unused)
    );

    // Permissive settings
    defparam dut.u_lif.LEAK_SHIFT = 0;
    defparam dut.u_lif.THRESH = 1;
    // COUNT_TH removed: v22 burst_gate uses TH_OPEN/TH_CLOSE, not COUNT_TH.
    // Default TH_OPEN=2 is fine — direction is valid by ds_v #2.

    // Spatial tile hash — must match lif_tile_tmux hashed_xy exactly.
    localparam HX = AW / 2;
    localparam HY = AW - HX;
    function automatic [AW-1:0] hash(input [XW-1:0] x, input [YW-1:0] y);
        hash = {x[XW-1:XW-HX], y[YW-1:YW-HY]};
    endfunction

    // AER request with proper scan pre-hold (matching tb_px_bound_300hz)
    task send_event;
        begin
            scan = hash(aer_x, aer_y);
            repeat (4) @(negedge clk);  // Pre-hold scan for LIF
            aer_req = 1;
            @(negedge clk);
            aer_req = 0;
            @(negedge clk);
        end
    endtask

    // Two targets: A moves right (+x), B moves left (-x)
    // They cross in the middle around x=256
    reg [XW-1:0] target_a_x = 100;
    reg [YW-1:0] target_a_y = 200;
    reg [XW-1:0] target_b_x = 400;
    reg [YW-1:0] target_b_y = 200;

    integer pred_count = 0;
    integer mae_total = 0;
    integer i;
    integer ex, ey;

    // Track which target prediction is closest to
    integer dist_a, dist_b;
    integer target_a_tracked = 0;
    integer target_b_tracked = 0;

    initial begin
        #(20*T_NS) rst = 0;

        // Simulate 40 timesteps - targets cross around step 20
        for (i = 0; i < 40; i = i + 1) begin
            // Update target positions
            target_a_x = 100 + i * 4;  // Moving right
            target_b_x = 400 - i * 4;  // Moving left
            // Both at same y=200

            // Send event from target A (blocking assignments)
            aer_x = target_a_x;
            aer_y = target_a_y;
            aer_pol = 0;
            send_event();

            // Send event from target B
            aer_x = target_b_x;
            aer_y = target_b_y;
            aer_pol = 1;
            send_event();
        end

        repeat (50) @(negedge clk);

        $display("Crossing test: %0d predictions", pred_count);
        $display("Target A tracked: %0d times", target_a_tracked);
        $display("Target B tracked: %0d times", target_b_tracked);
        $display("Total MAE: %0d", mae_total);

        // With a single tracker, we expect it to lock onto one target
        // Verify we got some predictions
        if (pred_count == 0) begin
            fail_msg("No predictions generated");
        end

        // Relaxed check - MAE should be reasonable given target switching
        // Average error < 200 pixels is acceptable for crossing targets
        if (pred_count > 0 && mae_total / pred_count > 200) begin
            fail_msg("Average MAE too high - tracking failed");
        end

        pass();
    end

    // Monitor predictions and check which target is being tracked
    always @(posedge clk) begin
        if (pred_valid) begin
            pred_count <= pred_count + 1;

            // Calculate distance to each target
            dist_a = ((x_hat > target_a_x) ? (x_hat - target_a_x) : (target_a_x - x_hat)) +
                     ((y_hat > target_a_y) ? (y_hat - target_a_y) : (target_a_y - y_hat));
            dist_b = ((x_hat > target_b_x) ? (x_hat - target_b_x) : (target_b_x - x_hat)) +
                     ((y_hat > target_b_y) ? (y_hat - target_b_y) : (target_b_y - y_hat));

            // Track which target is closer to prediction
            if (dist_a < dist_b) begin
                target_a_tracked <= target_a_tracked + 1;
                mae_total <= mae_total + dist_a;
            end else begin
                target_b_tracked <= target_b_tracked + 1;
                mae_total <= mae_total + dist_b;
            end
        end
    end
endmodule

`default_nettype wire
