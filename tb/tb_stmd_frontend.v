`timescale 1ns/1ps
`default_nettype none
// tb_stmd_frontend — replays front-end vectors produced by the fixed-point C
// reference (stmd/scripts/gen_fe_vectors.py) through rtl/stmd_frontend.v and
// checks the three output flags (activity filter, habituated, glare) are
// bit-exact for every event. Prints FAIL on any mismatch.
//
// Compile with -DFE_VEC='"path/to/fe_clean.hex"' (the vector file) and
// -DFE_DIR='"path/to/tables/"' (directory with the hex tables and
// fe_params.vh, which is also an include path). See sim/Makefile: stmd_fe.
module tb_stmd_frontend;
  localparam integer T_NS = 5;
  localparam integer MAXN = 65536;
  reg clk = 0, rst = 1; always #(T_NS/2) clk = ~clk;

  reg  [47:0] vec [0:MAXN-1];
  integer n_vec = 0;
  initial begin
    for (n_vec = 0; n_vec < MAXN; n_vec = n_vec + 1) vec[n_vec] = 48'hFFFFFFFFFFFF;
    $readmemh(`FE_VEC, vec);
    n_vec = 0;
    while (n_vec < MAXN && vec[n_vec] !== 48'hFFFFFFFFFFFF && ^vec[n_vec] !== 1'bx) n_vec = n_vec + 1;
  end

  reg        in_valid = 0; wire in_ready;
  reg  [8:0] in_x = 0; reg [8:0] in_y = 0; reg in_pol = 0; reg [15:0] in_t = 0;
  wire       out_valid, out_baf, out_hab, out_glare; wire [8:0] out_x, out_y; wire out_pol; wire [15:0] out_t, out_theta;

  localparam DIR = `FE_DIR;   // directory holding the table hex files, with trailing slash
  stmd_frontend #(
    .W(346), .H(260), .XW(9), .YW(9),
    .LUT_FLIP({DIR, "lut_flip.hex"}), .LUT_G({DIR, "lut_g.hex"}), .LUT_N({DIR, "lut_n.hex"}),
    .TBA_LUT({DIR, "tba_lut.hex"}), .NSUP_LUT({DIR, "nsup_lut.hex"}), .THETA_LUT({DIR, "theta_lut.hex"})
  ) dut (
    .clk(clk), .rst(rst), .in_valid(in_valid), .in_ready(in_ready),
    .in_x(in_x), .in_y(in_y), .in_pol(in_pol), .in_t_ms(in_t),
    .out_valid(out_valid), .out_x(out_x), .out_y(out_y), .out_pol(out_pol), .out_t_ms(out_t),
    .out_baf(out_baf), .out_hab(out_hab), .out_glare(out_glare), .out_theta_q4(out_theta)
  );

  integer i = 0, mism = 0, got = 0;
  reg [2:0] exp_bits;
  reg [47:0] w;

  // scoreboard: one outstanding event at a time (the DUT is single-issue)
  always @(posedge clk) begin
    if (!rst && out_valid) begin
      exp_bits = vec[got][42:40];
      if ({out_glare, out_hab, out_baf} !== exp_bits) begin
        mism = mism + 1;
        if (mism <= 10)
          $display("MISMATCH ev=%0d x=%0d y=%0d t=%0d exp(glare,hab,baf)=%b got=%b", got, vec[got][11:0], vec[got][22:12], vec[got][38:23], exp_bits, {out_glare, out_hab, out_baf});
      end
      got = got + 1;
    end
  end

  initial begin
    #(20*T_NS) rst = 0;
    @(negedge clk);
    for (i = 0; i < n_vec; i = i + 1) begin
      w = vec[i];
      while (!in_ready) @(negedge clk);
      in_x <= w[8:0]; in_y <= w[20:12]; in_pol <= w[39]; in_t <= w[38:23]; in_valid <= 1;
      @(negedge clk); in_valid <= 0;
      while (!in_ready) @(negedge clk);
    end
    repeat (40) @(negedge clk);
    $display("STMD_FE vectors=%0d outputs=%0d mismatches=%0d", n_vec, got, mism);
    if (got != n_vec) begin $display("FAIL: output count %0d != vector count %0d", got, n_vec); $finish_and_return(1); end
    else if (mism != 0) begin $display("FAIL: %0d mismatches", mism); $finish_and_return(1); end
    else begin $display("PASS"); $finish; end
  end

  initial begin
    #(5_000_000 * T_NS);
    $display("TIMEOUT"); $finish_and_return(1);
  end
endmodule
`default_nettype wire
