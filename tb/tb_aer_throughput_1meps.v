`timescale 1ns/1ps
`default_nettype none
module tb_aer_throughput_1meps;
  // 200 MHz -> 5 ns/clk. 1 Meps = 1 event / 1000 ns = 200 clocks per event.
  localparam integer T_NS = 5;
  localparam integer EVT_PERIOD_CYC = 200;   // target period (clks/event)
  localparam integer N_EVENTS       = 2000;  // short run for quick PASS/FAIL

  localparam XW=10, YW=10, AW=8, DW=0, PW=16;

  reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

  reg aer_req=0; wire aer_ack;
  reg [XW-1:0] aer_x=5; reg [YW-1:0] aer_y=6; reg aer_pol=0;
  reg [AW-1:0] scan=0;

  wire pred_valid; wire [PW-1:0] x_hat,y_hat; wire [7:0] conf; wire conf_valid;

  libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW)) dut(
    .clk(clk),.rst(rst),
    .aer_req(aer_req),.aer_ack(aer_ack),
    .aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
    .scan_addr(scan),
    .pred_valid(pred_valid),.x_hat(x_hat),.y_hat(y_hat),.conf(conf),.conf_valid(conf_valid)
  );

  // Throughput posture: fire on first hit, gate transparent; park scan on hash of (x,y)
  defparam dut.u_lif.LEAK_SHIFT = 0;
  defparam dut.u_lif.THRESH     = 1;
  defparam dut.u_bg.COUNT_TH    = 0;

  initial begin
    scan = (5 ^ 6) & ((1<<AW)-1);
  end

  // Edge detectors
  reg ack_q=0, pred_q=0;
  wire ack_rise  = (aer_ack   && !ack_q);
  wire pred_rise = (pred_valid && !pred_q);
  always @(posedge clk) begin
    ack_q  <= aer_ack;
    pred_q <= pred_valid;
  end

  integer n_req=0, n_ack=0, n_pred=0, n_xout=0;
  always @(posedge clk) if (ack_rise)  n_ack  <= n_ack  + 1;
  always @(posedge clk) if (pred_rise) n_pred <= n_pred + 1;
  // X/Z corruption monitor — catches undefined propagation from RTL bugs
  always @(posedge clk) if (^x_hat === 1'bx || ^y_hat === 1'bx) n_xout <= n_xout + 1;

  // 4-phase handshake @ exactly 1.0 Meps average (200 cycles per event)
  task send_event_1meps;
    integer c; // cycle counter for this event
    begin
      c = 0;

      // Phase 1: raise REQ with new coords
      aer_x  <= aer_x + 1;
      aer_req <= 1;
      n_req = n_req + 1;

      // Phase 2: wait ACK high
      while (aer_ack!==1) begin @(negedge clk); c = c + 1; end

      // Phase 3: drop REQ (advance one cycle)
      @(negedge clk); c = c + 1;
      aer_req <= 0;

      // Phase 4: wait ACK low
      while (aer_ack!==0) begin @(negedge clk); c = c + 1; end

      // Pad remaining cycles to complete EVT_PERIOD_CYC total
      while (c < EVT_PERIOD_CYC) begin @(negedge clk); c = c + 1; end
    end
  endtask

  integer i;
  initial begin
    #(20*T_NS) rst=0;

    // N_EVENTS @ 1.0 Meps equivalent period
    for (i=0;i<N_EVENTS;i=i+1) begin
      send_event_1meps();
    end

    // drain
    repeat (1000) @(negedge clk);

    $display("REQ=%0d ACK=%0d PRED=%0d XOUT=%0d", n_req, n_ack, n_pred, n_xout);

    if (n_ack != n_req) begin
      $display("FAIL: AER ack mismatch (drops)"); $finish_and_return(1);
    end
    if (n_xout > 0) begin
      $display("FAIL: X/Z corruption detected on outputs (%0d cycles)", n_xout);
      $finish_and_return(1);
    end
    $display("PASS");
    $finish;
  end
endmodule
`default_nettype wire
