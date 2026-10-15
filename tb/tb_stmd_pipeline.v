`timescale 1ns/1ps
`default_nettype none
// tb_stmd_pipeline — replays front-end vectors (stmd/scripts/gen_fe_vectors.py)
// through rtl/stmd_frontend.v chained into rtl/stmd_backend.v and checks the
// candidate flag and the final event label against the fixed-point C
// reference for every event. Prints FAIL on any mismatch, TIMEOUT if the
// pipeline stalls.
//
// Compile with -DFE_VEC='"path/to/fe_clean.hex"' and -DFE_DIR='"path/to/tables/"'
// (hex tables and fe_params.vh; also an include path). See sim/Makefile: stmd_pipe.
module tb_stmd_pipeline;
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

  reg        in_valid = 0; wire fe_ready, be_ready;
  reg  [8:0] in_x = 0; reg [8:0] in_y = 0; reg in_pol = 0; reg [15:0] in_t = 0;
  reg  [15:0] now_ms = 0;
  localparam integer IDLE_PER_MS = 128;     // compressed real time, as in tb_stmd_frontend
  wire       fe_valid, fe_baf, fe_hab, fe_glare; wire [8:0] fe_x, fe_y; wire fe_pol; wire [15:0] fe_t, fe_theta;
  wire       out_valid, out_label, out_cand, trk_valid; wire [31:0] trk_uid; wire signed [31:0] trk_x, trk_y;

  localparam DIR = `FE_DIR;
  stmd_frontend #(
    .W(346), .H(260), .XW(9), .YW(9),
    .LUT_FLIP({DIR, "lut_flip.hex"}), .LUT_G({DIR, "lut_g.hex"}), .LUT_N({DIR, "lut_n.hex"}),
    .TBA_LUT({DIR, "tba_lut.hex"}), .NSUP_LUT({DIR, "nsup_lut.hex"}), .THETA_LUT({DIR, "theta_lut.hex"})
  ) fe (
    .clk(clk), .rst(rst), .in_valid(in_valid), .in_ready(fe_ready),
    .in_x(in_x), .in_y(in_y), .in_pol(in_pol), .in_t_ms(in_t), .now_ms(now_ms),
    .out_valid(fe_valid), .out_x(fe_x), .out_y(fe_y), .out_pol(fe_pol), .out_t_ms(fe_t),
    .out_baf(fe_baf), .out_hab(fe_hab), .out_glare(fe_glare), .out_theta_q4(fe_theta)
  );
  stmd_backend #(
    .W(346), .H(260), .XW(9), .YW(9), .LUT_ACC({DIR, "lut_acc.hex"})
  ) be (
    .clk(clk), .rst(rst), .in_valid(fe_valid), .in_ready(be_ready),
    .in_x(fe_x), .in_y(fe_y), .in_pol(fe_pol), .in_t_ms(fe_t),
    .in_baf(fe_baf), .in_hab(fe_hab), .in_glare(fe_glare), .in_theta_q4(fe_theta), .now_ms(now_ms),
    .out_valid(out_valid), .out_label(out_label), .out_cand(out_cand),
    .trk_valid(trk_valid), .trk_uid(trk_uid), .trk_x_q8(trk_x), .trk_y_q8(trk_y)
  );

  integer i = 0, mism = 0, mism_cand = 0, got = 0, n_lab = 0, n_trk = 0, dropped = 0;
  reg [47:0] w;

  // the back end must be idle whenever the front end emits (single event in flight)
  always @(posedge clk) if (!rst && fe_valid && !be_ready) dropped = dropped + 1;

  always @(posedge clk) begin
    if (!rst && trk_valid) n_trk = n_trk + 1;
    if (!rst && out_valid) begin
      if (out_cand !== vec[got][44]) mism_cand = mism_cand + 1;
      if (out_label !== vec[got][45]) begin
        mism = mism + 1;
        if (mism <= 10)
          $display("MISMATCH ev=%0d x=%0d y=%0d t=%0d exp(label,cand)=%b%b got=%b%b", got, vec[got][11:0], vec[got][22:12], vec[got][38:23], vec[got][45], vec[got][44], out_label, out_cand);
      end
      n_lab = n_lab + out_label;
      got = got + 1;
    end
  end

  integer gap, c;
  reg [15:0] t_prev;
  initial begin
    #(20*T_NS) rst = 0;
    @(negedge clk);
    while (!(fe_ready && be_ready)) @(negedge clk);   // reset sweeps
    t_prev = 16'd0;
    for (i = 0; i < n_vec; i = i + 1) begin
      w = vec[i];
      gap = w[38:23] - t_prev;
      if (gap < 0) gap = gap + 65536;
      for (c = 0; c < gap; c = c + 1) begin
        repeat (IDLE_PER_MS) @(negedge clk);
        now_ms <= now_ms + 16'd1;
      end
      t_prev = w[38:23];
      while (!(fe_ready && be_ready && got == i)) @(negedge clk);
      in_x <= w[8:0]; in_y <= w[20:12]; in_pol <= w[39]; in_t <= w[38:23]; in_valid <= 1;
      @(negedge clk); in_valid <= 0;
      while (!(fe_ready && be_ready && got == i + 1)) @(negedge clk);
    end
    repeat (40) @(negedge clk);
    $display("STMD_PIPE vectors=%0d outputs=%0d label_mismatches=%0d cand_mismatches=%0d labels=%0d track_records=%0d", n_vec, got, mism, mism_cand, n_lab, n_trk);
    if (got != n_vec) begin $display("FAIL: output count %0d != vector count %0d", got, n_vec); $finish_and_return(1); end
    else if (dropped != 0) begin $display("FAIL: %0d front-end outputs while back end busy", dropped); $finish_and_return(1); end
    else if (mism != 0 || mism_cand != 0) begin $display("FAIL: %0d label / %0d candidate mismatches", mism, mism_cand); $finish_and_return(1); end
    else begin $display("PASS"); $finish; end
  end

  initial begin
    #(60_000_000 * T_NS);
    $display("TIMEOUT"); $finish_and_return(1);
  end
endmodule
`default_nettype wire
