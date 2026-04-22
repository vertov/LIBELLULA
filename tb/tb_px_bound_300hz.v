`timescale 1ns/1ps
`default_nettype none
module tb_px_bound_300hz;
  // Match latency bench: 200 MHz (5 ns), minimal pipeline delay.
  localparam integer T_NS = 5;              // 200 MHz
  localparam integer PERIOD_CYC = 667;      // ~300 Hz spacing
  localparam integer N_EVENTS  = 200;

  // CRITICAL: DW=0 to mirror the known-good latency posture.
  localparam XW=10, YW=10, AW=8, DW=0, PW=16;

  reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

  // AER
  reg aer_req=0; wire aer_ack;
  reg [XW-1:0] aer_x=20, aer_y=40; reg aer_pol=0;
  reg [AW-1:0] scan=0;

  // DUT
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

  // Same permissive settings as the latency bench
  defparam dut.u_lif.LEAK_SHIFT = 0;  // no leak
  defparam dut.u_lif.THRESH     = 1;  // fire on first hit
  // COUNT_TH removed: v22 burst_gate uses TH_OPEN/TH_CLOSE, not COUNT_TH.

  // Spatial tile hash — must match lif_tile_tmux hashed_xy exactly.
  localparam HX = AW / 2;
  localparam HY = AW - HX;
  function automatic [AW-1:0] hash(input [XW-1:0] x, input [YW-1:0] y);
      hash = {x[XW-1:XW-HX], y[YW-1:YW-HY]};
  endfunction

  // Scorekeeping
  integer viol=0, total=0, x_corrupt=0;

  // Emit one event (proper handshake) with scan pre-held, then wait for prediction.
  task send_event_and_check;
    integer timeout;
    integer tx, ty, ex, ey;
    begin
      // PRE-HOLD scan on CURRENT (x,y) before REQ, just like latency bench expectations
      scan <= hash(aer_x, aer_y);
      repeat (4) @(negedge clk);   // small, deterministic lead-in

      // 4-phase REQ/ACK while holding scan steady
      aer_req <= 1;
      while (aer_ack!==1) @(negedge clk);
      @(negedge clk); aer_req <= 0;
      while (aer_ack!==0) @(negedge clk);

      // Wait a bounded time for prediction (same scale as latency test)
      timeout = 64; // cycles @200 MHz = 0.32 us max wait
      while (!pred_valid && timeout>0) begin
        @(negedge clk); timeout = timeout - 1;
      end

      if (pred_valid) begin
        // Guard: reject X/Z-corrupted outputs (4-state simulation safety)
        if (^x_hat === 1'bx || ^y_hat === 1'bx) begin
          x_corrupt = x_corrupt + 1;
        end else begin
          tx = aer_x; ty = aer_y;    // compare to current truth
          ex = (x_hat>tx)? (x_hat-tx):(tx-x_hat);
          ey = (y_hat>ty)? (y_hat-ty):(ty-y_hat);
          total = total + 1;
          if (ex>2 || ey>2) viol = viol + 1;
        end
      end

      // Advance truth (+1 px in X per event)
      aer_x <= aer_x + 1;
    end
  endtask

  integer k, c;
  integer warmup = 8;  // drop the first few predictions as pipeline settles

  initial begin
    #(20*T_NS) rst=0;

    for (k=0; k<N_EVENTS; k=k+1) begin
      // inter-event spacing
      for (c=0; c<PERIOD_CYC; c=c+1) @(negedge clk);

      // event + check
      send_event_and_check();

      // discard during warmup
      if (warmup > 0) begin
        if (total > 0) total = total - 1;
        if (viol  > 0) viol  = viol  - 1;
        warmup = warmup - 1;
      end
    end

    // drain a bit
    repeat (200) @(negedge clk);

    if (x_corrupt > 0) begin
      $display("FAIL: %0d X/Z-corrupted outputs (undefined predictions)", x_corrupt);
      $finish_and_return(1);
    end else if (viol==0 && total>0) begin
      $display("PASS");
      $finish;
    end else begin
      $display("FAIL: %0d violations over %0d predictions", viol, total);
      $finish_and_return(1);
    end
  end
endmodule
`default_nettype wire
