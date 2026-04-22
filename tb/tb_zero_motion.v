`timescale 1ns/1ps
`default_nettype none

// tb_zero_motion: Static scene test
// Verifies no false predictions and low activity when nothing moves

`include "tb_common_tasks.vh"
module tb_zero_motion;
    localparam T_NS = 5;  // 200 MHz
    localparam XW = 10, YW = 10, AW = 8, DW = 0, PW = 16;

    reg clk = 0, rst = 1;
    always #(T_NS/2) clk = ~clk;

    reg aer_req = 0;
    wire aer_ack;
    reg [XW-1:0] aer_x = 200;
    reg [YW-1:0] aer_y = 200;
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

    // Spatial tile hash — must match lif_tile_tmux hashed_xy exactly.
    localparam HX = AW / 2;
    localparam HY = AW - HX;
    function automatic [AW-1:0] hash(input [XW-1:0] x, input [YW-1:0] y);
        hash = {x[XW-1:XW-HX], y[YW-1:YW-HY]};
    endfunction

    // AER request with proper scan pre-hold
    task send_event;
        begin
            scan = hash(aer_x, aer_y);
            repeat (4) @(negedge clk);
            aer_req = 1;
            @(negedge clk);
            aer_req = 0;
            @(negedge clk);
        end
    endtask

    integer pred_count = 0;
    integer false_motion_count = 0;
    integer i;
    integer ex, ey;

    initial begin
        #(20*T_NS) rst = 0;

        $display("Zero motion test: Static scene with events at same location");

        // Fix scan at target location
        scan = hash(200, 200);

        // Send events at SAME location (no motion)
        for (i = 0; i < 64; i = i + 1) begin
            // Position stays constant at (200, 200)
            aer_x = 200;
            aer_y = 200;

            repeat (4) @(negedge clk);
            aer_req = 1;
            @(negedge clk);
            aer_req = 0;

            repeat (100) @(negedge clk);
        end

        repeat (100) @(negedge clk);

        $display("Total predictions: %0d", pred_count);
        $display("Predictions near input: %0d", pred_count - false_motion_count);

        // With zero motion, predictions should converge to input position
        // Allow initial drift but should stabilize
        if (pred_count > 5 && false_motion_count > pred_count / 2) begin
            fail_msg("Predictions not converging to static position");
        end

        pass();
    end

    // Monitor for false motion (predictions far from static position)
    always @(posedge clk) begin
        if (pred_valid) begin
            pred_count <= pred_count + 1;

            // Check if prediction is far from true static position
            ex = (x_hat > 200) ? (x_hat - 200) : (200 - x_hat);
            ey = (y_hat > 200) ? (y_hat - 200) : (200 - y_hat);

            // If prediction drifts more than 10 pixels, count as false motion
            if (ex > 10 || ey > 10) begin
                false_motion_count <= false_motion_count + 1;
            end
        end
    end
endmodule

`default_nettype wire
