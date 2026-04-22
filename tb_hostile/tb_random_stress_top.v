`timescale 1ns/1ps
`default_nettype none

// Hostile bench: randomized stress of libellula_top.
//
// Focus:
// - Random bursts (including long idle periods)
// - Random coordinates/polarity
// - Optional reassertion of reset mid-stream
// - No X/Z on outputs
//
// This is *not* a model of a real DVS; it is a robustness sanity check.

module tb_random_stress_top;
    localparam integer T_NS = 5; // 200MHz
    localparam integer XW = 10;
    localparam integer YW = 10;
    localparam integer AW = 8;
    localparam integer DW = 6;
    localparam integer PW = 16;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(T_NS/2) clk = ~clk;

    reg aer_req = 1'b0;
    wire aer_ack;
    reg [XW-1:0] aer_x = 0;
    reg [YW-1:0] aer_y = 0;
    reg aer_pol = 0;

    reg [AW-1:0] scan_addr = 0;

    wire pred_valid;
    wire [PW-1:0] x_hat;
    wire [PW-1:0] y_hat;
    wire [7:0] conf;
    wire conf_valid;
    wire [1:0] tid_unused;

    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW)) dut (
        .clk(clk), .rst(rst),
        .aer_req(aer_req), .aer_ack(aer_ack),
        .aer_x(aer_x), .aer_y(aer_y), .aer_pol(aer_pol),
        .scan_addr(scan_addr),
        .pred_valid(pred_valid), .x_hat(x_hat), .y_hat(y_hat),
        .conf(conf), .conf_valid(conf_valid),
        .track_id(tid_unused)
    );

    // X/Z detection helper
    function has_x16;
        input [PW-1:0] v;
        begin
            has_x16 = (^v === 1'bx);
        end
    endfunction

    integer errors = 0;
    integer cycles = 0;
    reg [31:0] rng = 32'hC0FFEE11;

    task step;
        begin
            @(negedge clk);
            cycles = cycles + 1;
            // simple xorshift rng
            rng = rng ^ (rng << 13);
            rng = rng ^ (rng >> 17);
            rng = rng ^ (rng << 5);

            // Randomly toggle scan_addr (time-mux address) to mimic scanning
            scan_addr = rng[AW-1:0];

            // ~10% chance: assert a single-cycle aer_req pulse
            if (rng[3:0] == 4'h0) begin
                aer_x   = rng[XW-1:0];
                aer_y   = rng[YW-1:0];
                aer_pol = rng[0];
                aer_req = 1'b1;
            end else begin
                aer_req = 1'b0;
            end

            // Rare reset glitch (mid-stream): 1 cycle every ~512 cycles
            if (rng[8:0] == 9'h1A3) begin
                rst = 1'b1;
            end else if (rst && rng[2:0] == 3'b111) begin
                // deassert reset after a few cycles
                rst = 1'b0;
            end
        end
    endtask

    // Monitor
    always @(posedge clk) begin
        if (has_x16(x_hat) || has_x16(y_hat) || (^conf === 1'bx) || (pred_valid === 1'bx) || (conf_valid === 1'bx)) begin
            $display("ERROR: X/Z detected at t=%0t : pred_valid=%b conf_valid=%b x_hat=%h y_hat=%h conf=%h", $time, pred_valid, conf_valid, x_hat, y_hat, conf);
            errors = errors + 1;
        end
        if (rst) begin
            if (pred_valid !== 1'b0 || conf_valid !== 1'b0) begin
                $display("ERROR: valid asserted during reset at t=%0t : pred_valid=%b conf_valid=%b", $time, pred_valid, conf_valid);
                errors = errors + 1;
            end
        end
    end

    initial begin
        $display("=== HOSTILE: tb_random_stress_top ===");

        // Initial reset
        repeat (12) @(negedge clk);
        rst = 1'b0;

        // Run for a fixed budget
        for (cycles = 0; cycles < 5000; ) begin
            step();
        end

        // Drain
        repeat (50) @(negedge clk);

        if (errors == 0) $display("PASS");
        else $display("FAIL: errors=%0d", errors);
        $finish;
    end
endmodule

`default_nettype wire
