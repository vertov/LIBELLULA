`timescale 1ns/1ps
`default_nettype none

// Hostile bench: reset asserted mid-stream (top-level pipeline).
//
// PASS criteria (spec):
// 1) While rst=1, pred_valid and conf_valid must be 0.
// 2) When rst reasserts mid-stream, valids must drop within 1 cycle.
// 3) No X/Z on outputs (x_hat, y_hat, conf, pred_valid, conf_valid).
// 4) Determinism re-entry: repeating the same post-reset stimulus yields the same first N predictor outputs.

module tb_reset_midstream_top;
    localparam integer T_NS = 5; // 200 MHz
    localparam integer XW = 10;
    localparam integer YW = 10;
    localparam integer AW = 8;
    localparam integer DW = 0;  // DW=0: adjacent-spike Reichardt; generates ~9 pred_valid per phase
    localparam integer PW = 16;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(T_NS/2) clk = ~clk;

    reg aer_req = 1'b0;
    wire aer_ack;
    reg [XW-1:0] aer_x = {XW{1'b0}};
    reg [YW-1:0] aer_y = {YW{1'b0}};
    reg aer_pol = 1'b0;

    reg [AW-1:0] scan_addr = {AW{1'b0}};

    wire pred_valid;
    wire [PW-1:0] x_hat;
    wire [PW-1:0] y_hat;
    wire [7:0] conf;
    wire conf_valid;
    wire [1:0] tid_unused;

    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),.LIF_THRESH(4)) dut (
        .clk(clk), .rst(rst),
        .aer_req(aer_req), .aer_ack(aer_ack),
        .aer_x(aer_x), .aer_y(aer_y), .aer_pol(aer_pol),
        .scan_addr(scan_addr),
        .pred_valid(pred_valid), .x_hat(x_hat), .y_hat(y_hat),
        .conf(conf), .conf_valid(conf_valid),
        .track_id(tid_unused)
    );

    integer errors = 0;
    integer cap_idx = 0;
    integer cap2_idx = 0;

    reg [PW-1:0] cap_x1 [0:31];
    reg [PW-1:0] cap_y1 [0:31];
    reg [PW-1:0] cap_x2 [0:31];
    reg [PW-1:0] cap_y2 [0:31];

    // X/Z detection helper: reduction XOR yields X if any bit is X/Z
    function has_x;
        input [PW-1:0] v;
        begin
            has_x = (^v === 1'bx);
        end
    endfunction

    task send_event;
        input [XW-1:0] x;
        input [YW-1:0] y;
        input pol;
        begin
            @(negedge clk);
            aer_x = x;
            aer_y = y;
            aer_pol = pol;
            aer_req = 1'b1;
            @(negedge clk);
            aer_req = 1'b0;
        end
    endtask

    // Monitor: enforce no X and reset-valid behavior
    always @(posedge clk) begin
        // No-X checks
        if (has_x(x_hat) || has_x(y_hat) || (^conf === 1'bx) || (pred_valid === 1'bx) || (conf_valid === 1'bx)) begin
            $display("ERROR: X/Z detected at t=%0t : pred_valid=%b conf_valid=%b x_hat=%h y_hat=%h conf=%h",
                     $time, pred_valid, conf_valid, x_hat, y_hat, conf);
            errors = errors + 1;
        end

        // Reset contract: valids must be 0 while rst is asserted
        if (rst) begin
            if (pred_valid !== 1'b0 || conf_valid !== 1'b0) begin
                $display("ERROR: valid asserted during reset at t=%0t : pred_valid=%b conf_valid=%b", $time, pred_valid, conf_valid);
                errors = errors + 1;
            end
        end
    end

    // Capture first N phase-1 predictor outputs for determinism check.
    // Gated by phase1_done so phase-2 outputs don't bleed into cap_x1[].
    always @(posedge clk) begin
        if (!phase1_done && !rst && pred_valid) begin
            if (cap_idx < 32) begin
                cap_x1[cap_idx] <= x_hat;
                cap_y1[cap_idx] <= y_hat;
                cap_idx = cap_idx + 1;
            end
        end
    end

    // Phase 1 done flag: set just before mid-stream reset to stop phase-1 capture
    reg phase1_done = 1'b0;

    // Second capture window enabled after second reset
    reg capture2_en = 1'b0;
    always @(posedge clk) begin
        if (capture2_en && !rst && pred_valid) begin
            if (cap2_idx < 32) begin
                cap_x2[cap2_idx] <= x_hat;
                cap_y2[cap2_idx] <= y_hat;
                cap2_idx = cap2_idx + 1;
            end
        end
    end

    integer i;
    initial begin
        $display("=== HOSTILE: tb_reset_midstream_top ===");

        // Hold reset for a few cycles
        repeat (10) @(negedge clk);
        rst = 1'b0;

        // Stimulus phase 1: simple linear motion events
        for (i = 0; i < 40; i = i + 1) begin
            send_event(i[9:0], 10'd100, 1'b1);
        end

        // Drain phase 1 pipeline before closing the capture window.
        // Pipeline latency is ~8-10 cycles; 40 cycles ensures last pred_valid arrives.
        repeat (40) @(negedge clk);
        phase1_done = 1'b1;  // stop phase-1 capture before asserting reset

        // Assert reset mid-stream.
        // Hold for 2^AW + 10 = 266 cycles so the sequential state_mem clear
        // in lif_tile_tmux completes before we release reset.
        @(negedge clk);
        rst = 1'b1;
        repeat ((1<<AW) + 10) @(negedge clk);
        rst = 1'b0;

        // Clear indices for second capture
        capture2_en = 1'b1;

        // Repeat identical stimulus
        for (i = 0; i < 40; i = i + 1) begin
            send_event(i[9:0], 10'd100, 1'b1);
        end

        // Allow pipeline to drain
        repeat (40) @(negedge clk);

        // Determinism check: both phases must produce the same number of outputs
        if (cap_idx != cap2_idx) begin
            $display("ERROR: determinism count mismatch: phase1=%0d phase2=%0d outputs",
                     cap_idx, cap2_idx);
            errors = errors + 1;
        end
        // Determinism check for first 16 captured outputs (if present in both)
        for (i = 0; i < 16; i = i + 1) begin
            if (i < cap_idx && i < cap2_idx) begin
                if (cap_x1[i] !== cap_x2[i] || cap_y1[i] !== cap_y2[i]) begin
                    $display("ERROR: non-deterministic re-entry at sample %0d: (%h,%h) vs (%h,%h)",
                             i, cap_x1[i], cap_y1[i], cap_x2[i], cap_y2[i]);
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0) begin
            $display("PASS");
        end else begin
            $display("FAIL: errors=%0d", errors);
        end
        $finish;
    end
endmodule

`default_nettype wire
