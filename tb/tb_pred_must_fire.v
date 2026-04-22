`timescale 1ns/1ps
`default_nettype none

module tb_pred_must_fire;
    localparam T_NS = 10;
    localparam XW = 10;
    localparam YW = 10;
    localparam AW = 8;
    localparam DW = 4;
    localparam PW = 16;

    reg clk = 0;
    reg rst = 1;
    always #(T_NS/2) clk = ~clk;

    // DUT interface
    reg aer_req = 0;
    wire aer_ack;
    reg [XW-1:0] aer_x = 0;
    reg [YW-1:0] aer_y = 0;
    reg aer_pol = 0;
    reg [AW-1:0] scan = 0;
    always @(posedge clk) if (!rst) scan <= scan + 1'b1;

    wire pred_valid;
    wire [PW-1:0] x_hat;
    wire [PW-1:0] y_hat;
    wire [7:0] conf;
    wire conf_valid;

    wire [1:0] tid_unused;
    libellula_top #(.XW(XW), .YW(YW), .AW(AW), .DW(DW), .PW(PW)) dut (
        .clk(clk),
        .rst(rst),
        .aer_req(aer_req),
        .aer_ack(aer_ack),
        .aer_x(aer_x),
        .aer_y(aer_y),
        .aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid),
        .x_hat(x_hat),
        .y_hat(y_hat),
        .conf(conf),
        .conf_valid(conf_valid),
        .track_id(tid_unused)
    );

    integer pred_valid_count = 0;
    integer first_pred_cycle = -1;
    integer sim_cycle = 0;
    always @(posedge clk) begin
        if (rst) sim_cycle <= 0;
        else sim_cycle <= sim_cycle + 1;
    end
    always @(posedge clk) begin
        if (!rst && pred_valid) begin
            pred_valid_count <= pred_valid_count + 1;
            if (first_pred_cycle < 0)
                first_pred_cycle <= sim_cycle;
        end
    end

    localparam HX = AW / 2;
    localparam HY = AW - HX;
    function automatic [AW-1:0] hash_xy(input [XW-1:0] x, input [YW-1:0] y);
        hash_xy = {x[XW-1:XW-HX], y[YW-1:YW-HY]};
    endfunction

    task automatic emit_aligned(input [XW-1:0] x, input [YW-1:0] y, input integer spacing);
        reg [AW-1:0] target;
        begin
            target = hash_xy(x, y);
            // Advance until scan matches hash
            while (scan != target) @(posedge clk);
            @(negedge clk);
            aer_x <= x;
            aer_y <= y;
            aer_req <= 1'b1;
            @(negedge clk);
            aer_req <= 1'b0;
            repeat (spacing) @(negedge clk);
        end
    endtask

    integer i;
    reg [XW-1:0] cur_x;
    reg [YW-1:0] cur_y;
    integer x_step = 1;
    initial void'($value$plusargs("X_STEP=%d", x_step));

    initial begin
        // reset + warm-up
        repeat (128) @(negedge clk);
        rst = 0;
        repeat (64) @(negedge clk);
        cur_x = 16;
        cur_y = 32;
        for (i = 0; i < 64; i = i + 1) begin
            emit_aligned(cur_x, cur_y, 1);
            cur_x = cur_x + x_step;
        end
        repeat (256) @(negedge clk);
        if (pred_valid_count == 0) begin
            $display("PHASE4_RESULT test=must_fire status=FAIL first_cycle=-1 pred_count=0 total_cycle=%0d", sim_cycle);
            $finish_and_return(1);
        end else begin
            $display("PHASE4_RESULT test=must_fire status=PASS first_cycle=%0d pred_count=%0d total_cycle=%0d",
                     first_pred_cycle, pred_valid_count, sim_cycle);
            $finish;
        end
    end
endmodule

`default_nettype wire
