`timescale 1ns/1ps
`default_nettype none

// Lockstep replay bench for LIBELLULA Core v22.
//
// Drives the IDENTICAL stimulus used by tb_golden_gen and compares every
// pred_valid output against the frozen build/golden/expected.txt bit-exactly.
//
// Run `make golden_vectors` once to freeze the vectors, then
// `make replay_lockstep` on any RTL revision to verify bit-exact re-entry.

`include "tb_common_tasks.vh"
module tb_replay_lockstep;
    localparam T_NS  = 5;
    localparam XW = 10, YW = 10, AW = 8, DW = 0, PW = 16;
    localparam N_EVENTS = 80;
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

    integer fd_exp;
    integer errors = 0, pred_count = 0, golden_count = 0;
    reg [PW-1:0] exp_x, exp_y;
    integer scan_ret;
    integer t;
    // Temporary string buffer for header line (128 chars max)
    reg [8*128-1:0] hdr_buf;

    // Compare each pred_valid against the next golden line
    always @(posedge clk) begin
        if (!rst && pred_valid) begin
            scan_ret = $fscanf(fd_exp, "%h %h\n", exp_x, exp_y);
            if (scan_ret < 2) begin
                $display("REPLAY ERROR at pred #%0d: golden file ended early (scan_ret=%0d)",
                         pred_count, scan_ret);
                errors = errors + 1;
            end else begin
                golden_count = golden_count + 1;
                if (x_hat !== exp_x || y_hat !== exp_y) begin
                    $display("REPLAY MISMATCH pred#%0d: got x=%h y=%h  expected x=%h y=%h",
                             pred_count, x_hat, y_hat, exp_x, exp_y);
                    errors = errors + 1;
                end
            end
            pred_count = pred_count + 1;
        end
    end

    initial begin
        fd_exp = $fopen("build/golden/expected.txt", "r");
        if (fd_exp == 0) begin
            $display("REPLAY ERROR: cannot open build/golden/expected.txt");
            $display("  Run 'make golden_vectors' first to generate the golden file.");
            $finish;
        end
        // Skip comment header line
        $fgets(hdr_buf, fd_exp);

        repeat (20) @(negedge clk);
        rst = 1'b0;

        // Identical constant-velocity stimulus
        for (t = 0; t < N_EVENTS; t = t + 1) begin
            @(negedge clk);
            aer_x   = X_START + t;
            aer_y   = Y_FIXED;
            aer_pol = 1'b1;
            aer_req = 1'b1;
            @(negedge clk);
            aer_req = 1'b0;
        end

        repeat (40) @(negedge clk);
        $fclose(fd_exp);

        $display("REPLAY: %0d predictions seen, %0d matched against golden",
                 pred_count, golden_count);

        if (pred_count == 0) begin
            $display("REPLAY FAIL: no pred_valid outputs (check LIF_THRESH / DW params)");
            $finish;
        end
        if (errors == 0)
            $display("PASS");
        else
            $display("FAIL: %0d mismatches", errors);
        $finish;
    end
endmodule

`default_nettype wire
