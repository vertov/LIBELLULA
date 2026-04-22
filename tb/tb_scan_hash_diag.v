`timescale 1ns/1ps
`default_nettype none

module tb_scan_hash_diag;
    localparam T_NS = 10;
    localparam XW = 10;
    localparam YW = 10;
    localparam AW = 8;
    localparam DW = 4;
    localparam PW = 16;

    reg clk = 0;
    reg rst = 1;
    always #(T_NS/2) clk = ~clk;

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

    integer stim_mode = 0;
    integer event_count = 32;
    integer reset_cycles = 64;
    integer quiet_cycles = 32;
    integer target_x = 16;
    integer target_y = 8;
    reg [255:0] bench_name = "scan_diag";
    initial begin
        void'($value$plusargs("STIM_MODE=%d", stim_mode));
        void'($value$plusargs("EVENT_COUNT=%d", event_count));
        void'($value$plusargs("RESET_CYCLES=%d", reset_cycles));
        void'($value$plusargs("QUIET_CYCLES=%d", quiet_cycles));
        void'($value$plusargs("BENCH_NAME=%s", bench_name));
    end

    function [AW-1:0] hash_xy(input [XW-1:0] x, input [YW-1:0] y);
        hash_xy = (x ^ y) & {AW{1'b1}};
    endfunction

    task automatic emit_unscheduled(input integer idx);
        reg [XW-1:0] x_val;
        reg [YW-1:0] y_val;
        begin
            x_val = target_x + idx;
            y_val = target_y;
            @(negedge clk);
            aer_x <= x_val;
            aer_y <= y_val;
            aer_req <= 1'b1;
            @(negedge clk);
            aer_req <= 1'b0;
        end
    endtask

    task automatic emit_wait_match(input integer idx);
        reg [AW-1:0] hashed;
        reg [XW-1:0] x_val;
        reg [YW-1:0] y_val;
        begin
            x_val = target_x + idx;
            y_val = target_y;
            hashed = hash_xy(x_val, y_val);
            while (scan != hashed) @(posedge clk);
            @(negedge clk);
            aer_x <= x_val;
            aer_y <= y_val;
            aer_req <= 1'b1;
            @(negedge clk);
            aer_req <= 1'b0;
        end
    endtask

    task automatic emit_hold_until_hit(input integer idx);
        reg [AW-1:0] hashed;
        reg [XW-1:0] x_val;
        reg [YW-1:0] y_val;
        begin
            x_val = target_x + idx;
            y_val = target_y;
            hashed = hash_xy(x_val, y_val);
            aer_x <= x_val;
            aer_y <= y_val;
            aer_req <= 1'b1;
            while (scan != hashed) @(posedge clk);
            @(negedge clk);
            aer_req <= 1'b0;
        end
    endtask

    task automatic emit_retry(input integer idx);
        reg [AW-1:0] hashed;
        reg [XW-1:0] x_val;
        reg [YW-1:0] y_val;
        integer retries;
        begin : RETRY_LOOP
            x_val = target_x + idx;
            y_val = target_y;
            hashed = hash_xy(x_val, y_val);
            retries = 0;
            while (retries < 3) begin
                @(negedge clk);
                aer_x <= x_val;
                aer_y <= y_val;
                aer_req <= 1'b1;
                @(negedge clk);
                aer_req <= 1'b0;
                if (scan == hashed) disable RETRY_LOOP;
                retries = retries + 1;
            end
        end
    endtask

    integer i;
    initial begin
        repeat (reset_cycles) @(negedge clk);
        rst = 0;
        repeat (quiet_cycles) @(negedge clk);
        for (i = 0; i < event_count; i = i + 1) begin
            case (stim_mode)
                0: emit_unscheduled(i);
                1: begin emit_wait_match(i); end
                2: begin emit_hold_until_hit(i); end
                3: begin emit_retry(i); end
                default: emit_unscheduled(i);
            endcase
            repeat (2) @(negedge clk);
        end
        repeat (512) @(negedge clk);
        $display("SCAN_DONE mode=%0d events=%0d", stim_mode, event_count);
        $finish;
    end
endmodule

`default_nettype wire
