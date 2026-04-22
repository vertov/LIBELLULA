`timescale 1ns/1ps
`default_nettype none

module tb_lif_unit_diag #(
    parameter integer P_LEAK_SHIFT = 2,
    parameter integer P_THRESH = 16
);
    localparam T_NS = 10;
    localparam XW = 10;
    localparam YW = 10;
    localparam AW = 8;
    localparam SW = 14;

    reg clk = 0;
    reg rst = 1;
    always #(T_NS/2) clk = ~clk;

    reg in_valid = 0;
    reg [XW-1:0] in_x = 0;
    reg [YW-1:0] in_y = 0;
    reg in_pol = 0;
    reg [AW-1:0] scan = 0;

    reg [255:0] bench_name = "lif";
    integer target_addr = 5;
    integer hit_count = 32;
    integer hit_spacing = 1;
    integer scan_mode = 0; // 0: hold target, 1: free-run increment
    integer reset_cycles = 64;
    integer quiet_cycles = 32;
    initial begin
        void'($value$plusargs("BENCH_NAME=%s", bench_name));
        void'($value$plusargs("TARGET_ADDR=%d", target_addr));
        void'($value$plusargs("HIT_COUNT=%d", hit_count));
        void'($value$plusargs("HIT_SPACING=%d", hit_spacing));
        void'($value$plusargs("SCAN_MODE=%d", scan_mode));
        void'($value$plusargs("RESET_CYCLES=%d", reset_cycles));
        void'($value$plusargs("QUIET_CYCLES=%d", quiet_cycles));
    end

    lif_tile_tmux #(.XW(XW), .YW(YW), .AW(AW), .LEAK_SHIFT(P_LEAK_SHIFT), .THRESH(P_THRESH)) dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in_x(in_x),
        .in_y(in_y),
        .in_pol(in_pol),
        .scan_addr(scan),
        .out_valid(),
        .out_x(),
        .out_y(),
        .out_pol()
    );

    // Scan generator
    always @(posedge clk) begin
        if (rst) begin
            scan <= {AW{1'b0}};
        end else if (scan_mode == 0) begin
            scan <= target_addr[AW-1:0];
        end else begin
            scan <= scan + 1'b1;
        end
    end

    wire [SW-1:0] state_peek = dut.state_mem[target_addr];
    wire spike = dut.out_valid && (dut.out_x[AW-1:0] ^ dut.out_y[AW-1:0]) == target_addr[AW-1:0];

    integer sim_cycle = 0;
    always @(posedge clk) begin
        if (rst) sim_cycle <= 0;
        else sim_cycle <= sim_cycle + 1;
    end

    integer peak_state = 0;
    integer first_spike_cycle = -1;
    integer spike_count = 0;
    always @(posedge clk) begin
        if (!rst) begin
            if (state_peek > peak_state)
                peak_state <= state_peek;
            if (spike) begin
                spike_count <= spike_count + 1;
                if (first_spike_cycle < 0)
                    first_spike_cycle <= sim_cycle;
            end
        end
    end

    task automatic inject_hit;
        begin
            in_x <= target_addr[XW-1:0];
            in_y <= {YW{1'b0}};
            @(negedge clk);
            in_valid <= 1'b1;
            @(negedge clk);
            in_valid <= 0;
        end
    endtask

    task automatic wait_for_scan_match;
        begin
            while (scan != target_addr[AW-1:0]) @(posedge clk);
        end
    endtask

    integer i;
    initial begin
        repeat (reset_cycles) @(negedge clk);
        rst = 0;
        repeat (quiet_cycles) @(negedge clk);
        for (i = 0; i < hit_count; i = i + 1) begin
            wait_for_scan_match();
            inject_hit();
            repeat (hit_spacing) @(negedge clk);
        end
        repeat (256) @(negedge clk);
        $display("LIF_RESULT bench=%0s mode=%0d target=%0d hit_count=%0d hit_spacing=%0d peak=%0d spiked=%0d first_spike=%0d final_state=%0d leak_shift=%0d thresh=%0d",
                 bench_name, scan_mode, target_addr, hit_count, hit_spacing,
                 peak_state, (spike_count>0), first_spike_cycle, state_peek,
                 P_LEAK_SHIFT, P_THRESH);
        $finish;
    end
endmodule

`default_nettype wire
