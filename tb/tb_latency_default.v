`timescale 1ns/1ps
`default_nettype none
// tb_latency_default — latency and output cadence under DEFAULT parameters.
//
// tb_latency measures pipeline traversal in latency mode (LIF fires on the
// first hit, burst gate transparent). With default parameters the LIF tile
// must integrate several hits and the burst gate must open before anything
// reaches the predictor, so most events produce no prediction. This bench
// reports what a user of the default configuration sees:
//
//   * pipeline latency of every emitted prediction, measured from the newest
//     event presented before it (same counting convention as tb_latency);
//   * time and event count to the first prediction after reset;
//   * events per prediction over the run.
//
// Stimulus: one target moving +1 px/event in X, 667 cycles (3.3 us) between
// events at 200 MHz. Only the per-prediction latency is asserted (<= 5
// cycles); the cadence figures are characterisation output.
module tb_latency_default;
  localparam integer T_NS   = 5;
  localparam integer PERIOD = 667;
  localparam integer NEV    = 400;
  localparam integer LAT_MAX = 5;
  localparam XW=10, YW=10, AW=8, DW=0, PW=16;

  reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

  reg aer_req=0; wire aer_ack;
  reg [XW-1:0] aer_x=20; reg [YW-1:0] aer_y=40; reg aer_pol=0;
  reg [AW-1:0] scan=0;

  wire pred_valid; wire [PW-1:0] x_hat, y_hat; wire [7:0] conf; wire conf_valid;
  wire [1:0] tid_unused;
  libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW)) dut(
    .clk(clk), .rst(rst),
    .aer_req(aer_req), .aer_ack(aer_ack),
    .aer_x(aer_x), .aer_y(aer_y), .aer_pol(aer_pol),
    .scan_addr(scan),
    .pred_valid(pred_valid), .x_hat(x_hat), .y_hat(y_hat), .conf(conf), .conf_valid(conf_valid),
    .track_id(tid_unused)
  );

  // Cycle counter and event / prediction bookkeeping (all on posedge).
  integer cyc = 0;
  reg     req_q = 0;
  integer last_evt_cyc = -1;
  integer n_evt = 0, n_pred = 0;
  integer first_pred_cyc = -1, first_pred_evt = -1;
  integer lat, lat_min = 1 << 30, lat_max = -1, lat_bad = 0;

  always @(posedge clk) begin
    if (rst) begin
      cyc <= 0; req_q <= 0;
    end else begin
      cyc   <= cyc + 1;
      req_q <= aer_req;
      if (aer_req && !req_q) begin
        last_evt_cyc = cyc;
        n_evt = n_evt + 1;
      end
      if (pred_valid) begin
        n_pred = n_pred + 1;
        // tb_latency convention: cycles counted from the edge that samples
        // REQ to the edge before the one that samples pred_valid.
        lat = cyc - last_evt_cyc - 1;
        if (lat < lat_min) lat_min = lat;
        if (lat > lat_max) lat_max = lat;
        if (lat > LAT_MAX || last_evt_cyc < 0) lat_bad = lat_bad + 1;
        if (first_pred_cyc < 0) begin
          first_pred_cyc = cyc;
          first_pred_evt = n_evt;
        end
      end
    end
  end

  integer k, c;
  initial begin
    #(20*T_NS) rst = 0;
    for (k = 0; k < NEV; k = k + 1) begin
      for (c = 0; c < PERIOD; c = c + 1) @(negedge clk);
      // aer_rx is level-sensitive (one event per cycle REQ is high), so REQ
      // is a single-cycle pulse, as in tb_latency.
      aer_req <= 1;
      @(negedge clk); aer_req <= 0;
      aer_x <= aer_x + 1;
    end
    repeat (200) @(negedge clk);

    $display("LATDEF events=%0d predictions=%0d", n_evt, n_pred);
    if (n_pred > 0) begin
      $display("LATDEF pipeline latency per prediction: min=%0d max=%0d cycles", lat_min, lat_max);
      $display("LATDEF first prediction after %0d events (%0d cycles from reset)",
               first_pred_evt, first_pred_cyc);
      $display("LATDEF events per prediction = %0d.%01d",
               n_evt / n_pred, (10 * n_evt / n_pred) % 10);
    end

    if (n_pred == 0) begin
      $display("FAIL: no predictions under default parameters");
      $finish_and_return(1);
    end else if (lat_bad > 0) begin
      $display("FAIL: %0d predictions exceeded %0d-cycle latency", lat_bad, LAT_MAX);
      $finish_and_return(1);
    end
    $display("PASS");
    $finish;
  end
endmodule
`default_nettype wire
