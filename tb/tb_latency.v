`timescale 1ns/1ps
`default_nettype none
// tb_latency: Pipeline end-to-end latency measurement.
// Sends one event and measures clock cycles from aer_req to pred_valid.
// Requires COUNT_TH=0 (transparent burst gate) so ds_v #1 propagates
// immediately without needing TH_OPEN=2 accumulation.
// Specification: <= 12 cycles at 200 MHz (7-stage pipeline + margin).
module tb_latency;
  localparam integer T_NS = 5; // 200 MHz -> 5 ns/cycle
  localparam XW=10, YW=10, AW=8, DW=0, PW=16; // DW=0: minimal delay

  reg clk=0, rst=1; always #(T_NS/2) clk=~clk;

  reg aer_req=0; wire aer_ack;
  reg [XW-1:0] aer_x=12; reg [YW-1:0] aer_y=21; reg aer_pol=0;
  reg [AW-1:0] scan=0;

  wire pred_valid; wire [PW-1:0] x_hat, y_hat; wire [7:0] conf; wire conf_valid;
  wire [1:0] tid_unused;

  libellula_top #(.XW(XW),.YW(YW),.AW(AW),.DW(DW),.PW(PW)) dut(
    .clk(clk),.rst(rst),
    .aer_req(aer_req),.aer_ack(aer_ack),.aer_x(aer_x),.aer_y(aer_y),.aer_pol(aer_pol),
    .scan_addr(scan),
    .pred_valid(pred_valid),.x_hat(x_hat),.y_hat(y_hat),.conf(conf),.conf_valid(conf_valid),
    .track_id(tid_unused)
  );

  // Latency-mode: fire on first hit, gate transparent
  defparam dut.u_lif.LEAK_SHIFT = 0;
  defparam dut.u_lif.THRESH     = 1;
  defparam dut.u_bg.COUNT_TH    = 0; // pass immediately (v22 legacy parameter)

  // Spatial tile hash — must match lif_tile_tmux hashed_xy exactly.
  // hash(12,21) = {12[9:6], 21[9:6]} = {0,0} = 0 for AW=8, XW=10, YW=10
  localparam integer HX = AW / 2;
  localparam integer HY = AW - HX;
  initial scan = {aer_x[XW-1:XW-HX], aer_y[YW-1:YW-HY]};

  integer cycles = 0; bit started=0, stopped=0;

  // Start counting on the SAME clock edge that samples aer_req
  always @(posedge clk) begin
    if (rst) begin
      started <= 0; stopped <= 0; cycles <= 0;
    end else begin
      if (!started && aer_req) begin
        started <= 1; cycles <= 0;
      end else if (started && !stopped) begin
        // Check first, then increment to avoid off-by-one
        if (pred_valid) begin
          stopped <= 1;
        end else begin
          cycles <= cycles + 1;
        end
      end
    end
  end

  initial begin
    #(10*T_NS) rst = 0;
    // Single request
    @(negedge clk) aer_req <= 1;
    @(negedge clk) aer_req <= 0;

    // Wait for pred_valid with hard timeout to prevent infinite hang
    fork
      begin wait(stopped == 1'b1); end
      begin repeat(200) @(posedge clk); end
    join_any
    disable fork;

    if (!stopped) begin
      $display("FAIL: pred_valid did not assert within 200 cycles (pipeline stuck)");
      $finish_and_return(1);
    end

    $display("LATENCY_CYCLES=%0d", cycles);
    $display("LATENCY_NS=%0d", cycles*T_NS);
    if (cycles > 12) begin
      $display("FAIL: Latency %0d cycles exceeds 12-cycle specification", cycles);
      $finish_and_return(1);
    end
    $display("PASS");
    $finish;
  end
endmodule
`default_nettype wire
