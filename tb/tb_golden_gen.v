`timescale 1ns/1ps
`default_nettype none

// Golden vector generator for LIBELLULA Core v22.
//
// Runs the canonical constant-velocity scenario and writes:
//   build/golden/stimulus.evt  — one line per event: x y pol (decimal)
//   build/golden/expected.txt  — one line per pred_valid: x_hat y_hat (hex)
//
// Use `make golden_vectors` to generate; `make replay_lockstep` to verify.

`include "tb_common_tasks.vh"
module tb_golden_gen;
    localparam T_NS  = 5;
    localparam XW = 10, YW = 10, AW = 8, DW = 0, PW = 16;
    localparam N_EVENTS = 80;    // enough for burst_gate to open and predictor to warm up
    localparam X_START  = 10;
    localparam Y_FIXED  = 200;

    reg clk = 1'b0, rst = 1'b1;
    always #(T_NS/2) clk = ~clk;

    reg aer_req = 1'b0; wire aer_ack;
    reg [XW-1:0] aer_x = {XW{1'b0}};
    reg [YW-1:0] aer_y = {YW{1'b0}};
    reg aer_pol = 1'b0;
    reg [AW-1:0] scan = {AW{1'b0}};
    always @(posedge clk) if (!rst) scan <= scan + 1'b1;

    wire pred_valid; wire [PW-1:0] x_hat, y_hat; wire [7:0] conf; wire conf_valid;
    wire [1:0] tid_unused;

    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),.LIF_THRESH(4)) dut (
        .clk(clk),.rst(rst),
        .aer_req(aer_req),.aer_ack(aer_ack),
        .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
        .scan_addr(scan),
        .pred_valid(pred_valid),.x_hat(x_hat),.y_hat(y_hat),
        .conf(conf),.conf_valid(conf_valid),.track_id(tid_unused)
    );

    integer fd_stim, fd_exp;
    integer pred_count = 0;
    integer t;

    // Write each pred_valid output to expected.txt
    always @(posedge clk) begin
        if (!rst && pred_valid) begin
            $fwrite(fd_exp, "%04h %04h\n", x_hat, y_hat);
            pred_count = pred_count + 1;
        end
    end

    initial begin
        fd_stim = $fopen("build/golden/stimulus.evt", "w");
        fd_exp  = $fopen("build/golden/expected.txt",  "w");
        if (fd_stim == 0 || fd_exp == 0) begin
            $display("GOLDEN_GEN ERROR: cannot open output files in build/golden/");
            $display("  Run: mkdir -p build/golden");
            $finish;
        end

        // Canonical scenario header (informational only)
        $fwrite(fd_stim, "# LIBELLULA golden stimulus: x y pol (decimal); 1 event per line\n");
        $fwrite(fd_exp,  "# LIBELLULA golden expected: x_hat y_hat (hex 4-digit); 1 output per line\n");

        repeat (20) @(negedge clk);
        rst = 1'b0;

        // Constant-velocity rightward target
        for (t = 0; t < N_EVENTS; t = t + 1) begin
            @(negedge clk);
            aer_x   = X_START + t;
            aer_y   = Y_FIXED;
            aer_pol = 1'b1;
            aer_req = 1'b1;
            $fwrite(fd_stim, "%0d %0d %0d\n", aer_x, aer_y, aer_pol);
            @(negedge clk);
            aer_req = 1'b0;
        end

        // Pipeline drain (>= pipeline latency of ~8 cycles)
        repeat (40) @(negedge clk);

        $fclose(fd_stim);
        $fclose(fd_exp);

        $display("GOLDEN_GEN: %0d stimulus events, %0d pred_valid outputs written",
                 N_EVENTS, pred_count);
        if (pred_count == 0) begin
            $display("GOLDEN_GEN FAIL: zero pred_valid outputs — golden file empty");
            $finish;
        end
        $display("GOLDEN_GEN PASS");
        $finish;
    end
endmodule

`default_nettype wire
