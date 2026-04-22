`timescale 1ns/1ps
`default_nettype none

// tb_rotating_bar: Non-linear (circular) motion tracking test
// Verifies direction updates smoothly for rotating/curved trajectories

`include "tb_common_tasks.vh"
module tb_rotating_bar;
    localparam T_NS = 5;  // 200 MHz
    localparam XW = 10, YW = 10, AW = 8, DW = 0, PW = 16;

    reg clk = 0, rst = 1;
    always #(T_NS/2) clk = ~clk;

    reg aer_req = 0;
    wire aer_ack;
    reg [XW-1:0] aer_x = 100;
    reg [YW-1:0] aer_y = 100;
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

    // Circular motion parameters
    localparam RADIUS = 30;
    localparam CENTER_X = 100;
    localparam CENTER_Y = 100;

    // Direction tracking - check for smooth transitions
    reg signed [7:0] prev_dir_x = 0, prev_dir_y = 0;
    integer dir_jump_count = 0;
    integer pred_count = 0;
    integer angle;
    integer t;

    // Simple sine/cosine lookup (scaled by 100)
    function integer sin_lut;
        input integer a;
        begin
            case (a % 8)
                0: sin_lut = 0;
                1: sin_lut = 71;   // sin(45) * 100
                2: sin_lut = 100;  // sin(90) * 100
                3: sin_lut = 71;
                4: sin_lut = 0;
                5: sin_lut = -71;
                6: sin_lut = -100;
                7: sin_lut = -71;
            endcase
        end
    endfunction

    function integer cos_lut;
        input integer a;
        begin
            case (a % 8)
                0: cos_lut = 100;
                1: cos_lut = 71;
                2: cos_lut = 0;
                3: cos_lut = -71;
                4: cos_lut = -100;
                5: cos_lut = -71;
                6: cos_lut = 0;
                7: cos_lut = 71;
            endcase
        end
    endfunction

    initial begin
        #(20*T_NS) rst = 0;

        // Generate circular motion (64 events around a circle)
        for (angle = 0; angle < 64; angle = angle + 1) begin
            // Circular trajectory: x = cx + r*cos(theta), y = cy + r*sin(theta)
            aer_x <= CENTER_X + (RADIUS * cos_lut(angle) / 100);
            aer_y <= CENTER_Y + (RADIUS * sin_lut(angle) / 100);
            send_event();
        end

        repeat (50) @(negedge clk);

        // Check results
        $display("Rotating bar test: %0d predictions, %0d direction jumps", pred_count, dir_jump_count);

        // Allow some direction changes but not excessive jumping
        if (dir_jump_count > pred_count / 2) begin
            fail_msg("Too many direction jumps - not tracking smoothly");
        end

        pass();
    end

    // Monitor direction smoothness
    always @(posedge clk) begin
        if (pred_valid) begin
            pred_count <= pred_count + 1;

            // Check if direction changed abruptly (sign flip)
            if (pred_count > 8) begin  // After warmup
                if ((prev_dir_x > 20 && dut.dir_x < -20) ||
                    (prev_dir_x < -20 && dut.dir_x > 20) ||
                    (prev_dir_y > 20 && dut.dir_y < -20) ||
                    (prev_dir_y < -20 && dut.dir_y > 20)) begin
                    dir_jump_count <= dir_jump_count + 1;
                end
            end
            prev_dir_x <= dut.dir_x;
            prev_dir_y <= dut.dir_y;
        end
    end
endmodule

`default_nettype wire
