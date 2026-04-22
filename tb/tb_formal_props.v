`timescale 1ns/1ps
`default_nettype none

// Bounded-simulation formal properties bench for LIBELLULA Core v22.
//
// NOTE: Full SVA-based model checking requires SymbiYosys (sby).  This bench
// uses a 50 000-cycle LFSR-driven pseudo-random stimulus and hierarchical
// assertions to provide bounded verification evidence for the same properties.
//
// PROPERTIES VERIFIED
//  P1  Reset safety      : pred_valid === 0 AND conf_valid === 0 while rst=1
//  P2  No X/Z on outputs : pred_valid, conf_valid, aer_ack always have known values
//  P3  State clear       : after 2^AW consecutive reset cycles, ALL state_mem[] = 0
//  P4  Output saturation : when pred_valid, x_hat[PW-1:XW] = 0 and y_hat[PW-1:YW] = 0
//  P5  Determinism       : two DUTs with identical stimulus produce bit-exact outputs

module tb_formal_props;
    localparam T_NS = 5;
    localparam XW = 10, YW = 10, AW = 8, DW = 0, PW = 16;
    localparam N_CYCLES = 50000;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #(T_NS/2) clk = ~clk;

    // 32-bit Galois LFSR for pseudo-random stimulus
    reg [31:0] lfsr = 32'hDEAD_BEEF;
    always @(posedge clk)
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

    // ---- DUT A ----
    reg  aer_req_a = 1'b0;
    wire aer_ack_a;
    reg  [XW-1:0] aer_x_a  = {XW{1'b0}};
    reg  [YW-1:0] aer_y_a  = {YW{1'b0}};
    reg           aer_pol_a = 1'b0;
    reg  [AW-1:0] scan_a   = {AW{1'b0}};
    always @(posedge clk) if (!rst) scan_a <= scan_a + 1'b1;

    wire          pred_valid_a;
    wire [PW-1:0] x_hat_a, y_hat_a;
    wire [7:0]    conf_a;
    wire          conf_valid_a;
    wire [1:0]    tid_a;

    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),.LIF_THRESH(4)) dut_a (
        .clk(clk),.rst(rst),
        .aer_req(aer_req_a),.aer_ack(aer_ack_a),
        .aer_x(aer_x_a),.aer_y(aer_y_a),.aer_pol(aer_pol_a),
        .scan_addr(scan_a),
        .pred_valid(pred_valid_a),.x_hat(x_hat_a),.y_hat(y_hat_a),
        .conf(conf_a),.conf_valid(conf_valid_a),.track_id(tid_a)
    );

    // ---- DUT B (identical stimulus for P5) ----
    wire          pred_valid_b;
    wire [PW-1:0] x_hat_b, y_hat_b;
    wire [7:0]    conf_b;
    wire          conf_valid_b;
    wire [1:0]    tid_b;

    libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW),.LIF_THRESH(4)) dut_b (
        .clk(clk),.rst(rst),
        .aer_req(aer_req_a),.aer_ack(),.aer_x(aer_x_a),.aer_y(aer_y_a),.aer_pol(aer_pol_a),
        .scan_addr(scan_a),
        .pred_valid(pred_valid_b),.x_hat(x_hat_b),.y_hat(y_hat_b),
        .conf(conf_b),.conf_valid(conf_valid_b),.track_id(tid_b)
    );

    integer errors = 0;
    integer cyc    = 0;
    integer i;

    // --- Per-cycle property checks (posedge) ---
    always @(posedge clk) begin
        cyc = cyc + 1;

        // P1: valid suppression during reset
        if (rst) begin
            if (pred_valid_a !== 1'b0) begin
                $display("[P1 FAIL cyc=%0d] pred_valid_a asserted while rst=1", cyc);
                errors = errors + 1;
            end
            if (conf_valid_a !== 1'b0) begin
                $display("[P1 FAIL cyc=%0d] conf_valid_a asserted while rst=1", cyc);
                errors = errors + 1;
            end
        end

        // P2: no X/Z on key outputs
        if ((^pred_valid_a === 1'bx) || (^conf_valid_a === 1'bx) || (^aer_ack_a === 1'bx)) begin
            $display("[P2 FAIL cyc=%0d] X/Z on output (pred_valid=%b conf_valid=%b ack=%b)",
                     cyc, pred_valid_a, conf_valid_a, aer_ack_a);
            errors = errors + 1;
        end

        // P4: output saturation — upper bits must be 0 when pred_valid
        if (pred_valid_a) begin
            if (x_hat_a[PW-1:XW] !== {(PW-XW){1'b0}}) begin
                $display("[P4 FAIL cyc=%0d] x_hat overflow: x_hat=%h", cyc, x_hat_a);
                errors = errors + 1;
            end
            if (y_hat_a[PW-1:YW] !== {(PW-YW){1'b0}}) begin
                $display("[P4 FAIL cyc=%0d] y_hat overflow: y_hat=%h", cyc, y_hat_a);
                errors = errors + 1;
            end
        end

        // P5: determinism — two identically-driven DUTs must match
        if (pred_valid_a !== pred_valid_b ||
            (pred_valid_a && (x_hat_a !== x_hat_b || y_hat_a !== y_hat_b))) begin
            $display("[P5 FAIL cyc=%0d] DUT divergence: a=(%h,%h valid=%b) b=(%h,%h valid=%b)",
                     cyc, x_hat_a, y_hat_a, pred_valid_a, x_hat_b, y_hat_b, pred_valid_b);
            errors = errors + 1;
        end
    end

    // --- LFSR stimulus (negedge to avoid race) ---
    always @(negedge clk) begin
        if (!rst) begin
            aer_req_a <= lfsr[0];
            aer_x_a   <= lfsr[10:1];
            aer_y_a   <= lfsr[20:11];
            aer_pol_a <= lfsr[21];
        end else begin
            aer_req_a <= 1'b0;
        end
    end

    initial begin
        $display("=== FORMAL PROPS (bounded simulation, %0d cycles, LFSR seed=0xDEADBEEF) ===",
                 N_CYCLES);

        // Short initial reset
        repeat (10) @(negedge clk);
        rst = 1'b0;

        // Phase 1: random stimulus
        repeat (N_CYCLES / 2) @(negedge clk);

        // P3: assert reset for exactly 2^AW + 5 cycles
        @(negedge clk); rst = 1'b1;
        repeat ((1<<AW) + 5) @(negedge clk);

        // Hierarchical check: all state_mem cells must be zero
        for (i = 0; i < (1<<AW); i = i + 1) begin
            if (dut_a.u_lif.state_mem[i] !== {14{1'b0}}) begin
                $display("[P3 FAIL] state_mem[%0d]=%h != 0 after 2^AW reset cycles",
                         i, dut_a.u_lif.state_mem[i]);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("[P3 PASS] All %0d state_mem cells = 0 after 2^AW reset cycles", (1<<AW));

        @(negedge clk); rst = 1'b0;

        // Phase 2: continued random stimulus
        repeat (N_CYCLES / 2) @(negedge clk);

        if (errors == 0)
            $display("PASS: all bounded properties hold over %0d cycles", N_CYCLES);
        else
            $display("FAIL: %0d property violation(s) detected", errors);
        $finish;
    end
endmodule

`default_nettype wire
