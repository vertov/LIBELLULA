`timescale 1ns/1ps
`default_nettype none
// tb_px_bound — steady-state one-step prediction error, constant velocity.
//
// Replaces tb_px_bound_300hz (v22 and earlier). That bench spaced events by
// 667 cycles at 200 MHz (3.3 us, i.e. ~300 k events/s, not 300 Hz) and
// scored x_hat against the CURRENT event position, so a core that echoed its
// input would also have passed.
//
// This bench scores x_hat against the NEXT event position (the quantity a
// one-step predictor is estimating) and runs with a configurable step so a
// pure echo fails: at STEP_PX = 3 an echo has 3 px error, above the 2 px
// bound. The bench also fails if mean one-step error is not below the echo
// baseline (STEP px), i.e. if the core is not actually extrapolating.
//
// Overrides (iverilog -D):
//   PERIOD_CYC  cycles between events   (default 667     = 300 k events/s)
//                                        (666667          = 300 events/s)
//   STEP_PX     px per event in X        (default 1)
//   N_EVENTS    events in the run        (default 200)
//
// LIF is configured fire-on-first-hit (THRESH=1, LEAK_SHIFT=0), DW=0, so every
// event reaches the predictor. This measures predictor accuracy, not the
// default-parameter gating behaviour (see benchmarks/ for that).
module tb_px_bound;
  localparam integer T_NS = 5;              // 200 MHz
`ifdef PERIOD_CYC
  localparam integer PERIOD = `PERIOD_CYC;
`else
  localparam integer PERIOD = 667;
`endif
`ifdef STEP_PX
  localparam integer STEP = `STEP_PX;
`else
  localparam integer STEP = 1;
`endif
`ifdef N_EVENTS
  localparam integer NEV = `N_EVENTS;
`else
  localparam integer NEV = 200;
`endif
  localparam integer BOUND_PX = 2;

  localparam XW=10, YW=10, AW=8, DW=0, PW=16;

  reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

  reg aer_req=0; wire aer_ack;
  reg [XW-1:0] aer_x=20, aer_y=40; reg aer_pol=0;
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

  defparam dut.u_lif.LEAK_SHIFT = 0;  // no leak
  defparam dut.u_lif.THRESH     = 1;  // fire on first hit

  localparam HX = AW / 2;
  localparam HY = AW - HX;
  function automatic [AW-1:0] hash(input [XW-1:0] x, input [YW-1:0] y);
      hash = {x[XW-1:XW-HX], y[YW-1:YW-HY]};
  endfunction

  integer viol=0, total=0, x_corrupt=0, missed=0;
  integer sum_err=0, max_err=0, sum_echo=0;
  integer warmup = 8;

  task send_event_and_check;
    integer timeout;
    integer nx, ex, ey;
    begin
      scan <= hash(aer_x, aer_y);
      repeat (4) @(negedge clk);

      // aer_rx is level-sensitive: every cycle REQ is high is one event, so
      // REQ is a single-cycle pulse. (v22 held REQ for two cycles, which
      // injected each position twice.)
      aer_req <= 1;
      @(negedge clk); aer_req <= 0;

      timeout = 64;
      while (!pred_valid && timeout>0) begin
        @(negedge clk); timeout = timeout - 1;
      end

      if (!pred_valid) begin
        if (warmup == 0) missed = missed + 1;
      end else if (^x_hat === 1'bx || ^y_hat === 1'bx) begin
        x_corrupt = x_corrupt + 1;
      end else if (warmup == 0) begin
        nx = aer_x + STEP;                       // next true position
        ex = (x_hat > nx) ? (x_hat - nx) : (nx - x_hat);
        ey = (y_hat > aer_y) ? (y_hat - aer_y) : (aer_y - y_hat);
        total    = total + 1;
        sum_err  = sum_err + ex;
        sum_echo = sum_echo + STEP;               // echo baseline error
        if (ex > max_err) max_err = ex;
        if (ex > BOUND_PX || ey > BOUND_PX) viol = viol + 1;
      end

      if (warmup > 0) warmup = warmup - 1;
      aer_x <= aer_x + STEP;
    end
  endtask

  integer k, c;

  initial begin
    #(20*T_NS) rst=0;

    for (k=0; k<NEV; k=k+1) begin
      for (c=0; c<PERIOD; c=c+1) @(negedge clk);
      send_event_and_check();
    end

    repeat (200) @(negedge clk);

    $display("PXBOUND period=%0d cyc step=%0d px events=%0d scored=%0d missed=%0d",
             PERIOD, STEP, NEV, total, missed);
    if (total > 0)
      $display("PXBOUND one-step err: mean=%0d.%02d px max=%0d px (echo baseline %0d px) bound=%0d px",
               sum_err/total, (100*sum_err/total)%100, max_err, sum_echo/total, BOUND_PX);

    if (x_corrupt > 0) begin
      $display("FAIL: %0d X/Z-corrupted outputs", x_corrupt);
      $finish_and_return(1);
    end else if (total == 0 || missed > 0) begin
      $display("FAIL: %0d scored, %0d events without a prediction", total, missed);
      $finish_and_return(1);
    end else if (viol > 0) begin
      $display("FAIL: %0d violations over %0d predictions", viol, total);
      $finish_and_return(1);
    end else if (sum_err >= sum_echo) begin
      // Within the bound but no better than repeating the last event:
      // the predictor is not extrapolating.
      $display("FAIL: mean one-step error not below echo baseline");
      $finish_and_return(1);
    end else begin
      $display("PASS");
      $finish;
    end
  end
endmodule
`default_nettype wire
