`timescale 1ns/1ps
`default_nettype none

// Full reference pipeline per whitepaper (simplified, synthesizable):
// AER -> LIF (time-mux) -> Delay Lattice -> Reichardt DS -> Burst Gate -> α-β Predictor -> Confidence
//
// TIMING CONTRACT (cycle numbers relative to AER event arrival):
// +---------+------+------------------+----------------------------------------+
// | Stage   | Δ    | Signal           | Description                            |
// +---------+------+------------------+----------------------------------------+
// | AER RX  | +0   | ev_v, ev_x       | Event captured from AER bus            |
// | LIF     | +2   | lif_v, lif_x     | Spike after 2-stage pipeline           |
// | Delay   | +3   | v_e, x_tap       | Correlation taps and coords (reg'd)    |
// | Reich.  | +4   | ds_v, dir_x      | Direction after correlation+compute    |
// | Burst   | +5   | bg_v             | Gated valid (registered)               |
// | Pred    | +6   | pred_v, x_hat    | Prediction output (registered)         |
// +---------+------+------------------+----------------------------------------+
//
// To align coordinates with direction signals:
// - x_tap arrives at +3, dir_x at +4
// - We delay x_tap by 1 cycle -> x_t_d1 at +4 (aligned with dir_x)
// - burst_gate and predictor use ds_v/dir_x/x_t_d1 which are all aligned
//
module libellula_top #(
    // DW=0 (DEPTH=1): correlate each LIF spike against the immediately previous one.
    // Correct for tile-based LIF where consecutive spikes = consecutive tile activations.
    // Increase DW only if multiple targets or high-noise environments require longer history.
    // UAV profile: DW=6 (64-event ring buffer) for dense-target direction detection.
    parameter XW=10, YW=10, AW=8, DW=0, PW=16,
    // Tile step: coordinate distance between adjacent LIF neurons' spike outputs.
    // lif_tile_tmux outputs TILE INDICES (0..2^(AW/2)-1) not pixel coords, so
    // adjacent tiles always differ by exactly 1. Always use TILE_STEP=1.
    parameter TILE_STEP = 1,
    // Multi-target tracker pool size.
    // NTRACK=1: single ab_predictor (original behaviour, no overhead).
    // NTRACK>1: tracker_pool with N=NTRACK instances. Adds track_id output.
    parameter NTRACK = 1,
    parameter ASSIGN_TH = 96,     // L1 assignment threshold in pixels (pool only)
    parameter COAST_TIMEOUT = 4,  // missed-update retirement count (pool only)
    // -------------------------------------------------------------------------
    // LIF neuron tuning  (v22 defaults; UAV profile values shown in comments)
    // -------------------------------------------------------------------------
    parameter integer LIF_LEAK_SHIFT = 4,    // membrane decay  (UAV: 14 = 99.99% retention)
    parameter integer LIF_THRESH     = 16,   // spike threshold (UAV: 4  = hair-trigger)
    parameter integer LIF_HIT_WEIGHT = 1,    // charge per hit  (UAV: 8192)
    // -------------------------------------------------------------------------
    // Burst gate tuning  (v22 defaults; UAV profile values shown in comments)
    // -------------------------------------------------------------------------
    parameter integer BG_TH_OPEN    = 2,     // gate-open threshold  (UAV: 1)
    parameter integer BG_TH_CLOSE   = 1,     // gate-close threshold (UAV: 0)
    // BG_WINDOW_OVR: 0 = auto (1<<AW+12, accumulator semantics, required for
    //   TH_OPEN=2 / VEL_INIT cold-start invariant).  >0 = explicit override.
    //   UAV profile uses BG_WINDOW_OVR=4 (short density window); when doing so
    //   also set BG_TH_OPEN=1 — the TH_OPEN=2 invariant no longer applies at
    //   UAV event densities where bg_v fires well within any 4-scan window.
    parameter integer BG_WINDOW_OVR = 0
)(
    input  wire clk, rst,
    // AER interface
    input  wire          aer_req,
    output wire          aer_ack,
    input  wire [XW-1:0] aer_x,
    input  wire [YW-1:0] aer_y,
    input  wire          aer_pol,
    // Control (for LIF scan)
    input  wire [AW-1:0] scan_addr,
    // Outputs
    output wire          pred_valid,
    output wire [PW-1:0] x_hat,
    output wire [PW-1:0] y_hat,
    output wire [7:0]    conf,
    output wire          conf_valid,
    // track_id: which pool tracker fired (always 0 when NTRACK=1)
    output wire [1:0]    track_id
);

    //=========================================================================
    // Stage 1: AER Receiver (+0 cycles)
    //=========================================================================
    wire ev_v;
    wire [XW-1:0] ev_x;
    wire [YW-1:0] ev_y;
    wire ev_p;

    aer_rx #(.XW(XW),.YW(YW)) u_rx (
        .clk(clk), .rst(rst),
        .aer_req(aer_req), .aer_ack(aer_ack),
        .aer_x(aer_x), .aer_y(aer_y), .aer_pol(aer_pol),
        .ev_valid(ev_v), .ev_x(ev_x), .ev_y(ev_y), .ev_pol(ev_p)
    );

    //=========================================================================
    // Stage 2: LIF Time-Multiplexed Array (+2 cycles due to 2-stage pipeline)
    //=========================================================================
    wire lif_v;
    wire [XW-1:0] lif_x;   // tile-snapped x (for delay lattice)
    wire [YW-1:0] lif_y;   // tile-snapped y
    wire lif_p;
    wire [XW-1:0] lif_ex;  // exact event pixel x (for predictor)
    wire [YW-1:0] lif_ey;  // exact event pixel y

    lif_tile_tmux #(
        .XW(XW),.YW(YW),.AW(AW),
        .LEAK_SHIFT(LIF_LEAK_SHIFT),
        .THRESH(LIF_THRESH),
        .HIT_WEIGHT(LIF_HIT_WEIGHT)
    ) u_lif (
        .clk(clk), .rst(rst),
        .in_valid(ev_v), .in_x(ev_x), .in_y(ev_y), .in_pol(ev_p),
        .scan_addr(scan_addr),
        .out_valid(lif_v), .out_x(lif_x), .out_y(lif_y), .out_pol(lif_p),
        .out_ex(lif_ex), .out_ey(lif_ey)
    );

    //=========================================================================
    // Stage 3: Delay Lattice (+3 cycles - outputs are registered)
    // Now provides 8-direction correlation (4 cardinal + 4 diagonal)
    //=========================================================================
    wire v_e, v_w, v_n, v_s;           // Cardinal directions
    wire v_ne, v_nw, v_se, v_sw;       // Diagonal directions
    wire [XW-1:0] x_tap;
    wire [YW-1:0] y_tap;

    delay_lattice_rb #(.XW(XW),.YW(YW),.DW(DW),.STEP(TILE_STEP)) u_dl (
        .clk(clk), .rst(rst),
        .in_valid(lif_v), .in_x(lif_x), .in_y(lif_y), .in_pol(lif_p),
        // Cardinal correlation outputs
        .v_e(v_e), .v_w(v_w), .v_n(v_n), .v_s(v_s),
        // Diagonal correlation outputs
        .v_ne(v_ne), .v_nw(v_nw), .v_se(v_se), .v_sw(v_sw),
        .x_tap(x_tap), .y_tap(y_tap),
        /* verilator lint_off PINCONNECTEMPTY */
        .pol_tap()   // polarity not used by downstream pipeline stages
        /* verilator lint_on  PINCONNECTEMPTY */
    );

    // Delay lif_v by 1 cycle to align with delay_lattice outputs
    // This ensures reichardt sees in_valid when v_e/v_w/v_n/v_s are valid
    reg lif_v_d1 = 1'b0;
    always @(posedge clk) begin
        if (rst)
            lif_v_d1 <= 1'b0;
        else
            lif_v_d1 <= lif_v;
    end

    //=========================================================================
    // Stage 4: Reichardt Direction Selectivity (+4 cycles)
    // Uses lif_v_d1 so in_valid aligns with correlation taps from delay_lattice
    // Now processes 8 directions (4 cardinal + 4 diagonal)
    //=========================================================================
    wire ds_v;
    wire signed [7:0] dir_x, dir_y;

    reichardt_ds u_ds (
        .clk(clk), .rst(rst),
        // Cardinal direction taps
        .v_e(v_e), .v_w(v_w), .v_n(v_n), .v_s(v_s),
        // Diagonal direction taps
        .v_ne(v_ne), .v_nw(v_nw), .v_se(v_se), .v_sw(v_sw),
        .in_valid(lif_v_d1),
        .out_valid(ds_v), .dir_x(dir_x), .dir_y(dir_y)
    );

    // Pipeline registers to align tile-snapped coordinates with direction signals.
    // x_tap available at +3 (registered inside delay_lattice), delay 1 more -> +4 (aligns with dir_x).
    reg [XW-1:0] x_t_d1 = {XW{1'b0}};
    reg [YW-1:0] y_t_d1 = {YW{1'b0}};
    // Parallel chain: exact event pixel coords (lif_ex/lif_ey at +2) delayed to +4.
    // lif_ex latency from LIF = 0 extra stages (registered in lif_tile_tmux at +2 already).
    // We need +2 more cycles to align with x_t_d1 (+3 → +4 in the tile path).
    reg [XW-1:0] ex_d1 = {XW{1'b0}};
    reg [YW-1:0] ey_d1 = {YW{1'b0}};
    reg [XW-1:0] ex_d2 = {XW{1'b0}};
    reg [YW-1:0] ey_d2 = {YW{1'b0}};
    always @(posedge clk) begin
        if (rst) begin
            x_t_d1 <= {XW{1'b0}};
            y_t_d1 <= {YW{1'b0}};
            ex_d1  <= {XW{1'b0}};
            ey_d1  <= {YW{1'b0}};
            ex_d2  <= {XW{1'b0}};
            ey_d2  <= {YW{1'b0}};
        end else begin
            x_t_d1 <= x_tap;
            y_t_d1 <= y_tap;
            ex_d1  <= lif_ex;
            ey_d1  <= lif_ey;
            ex_d2  <= ex_d1;
            ey_d2  <= ey_d1;
        end
    end

    //=========================================================================
    // Stage 5: Burst Gate (+5 cycles - output is registered)
    // Filters sporadic events, only passes when density threshold met
    //=========================================================================
    wire bg_v;

    // Burst gate window: default = auto-large (1<<AW+12, ~5ms at 200MHz for AW=8)
    // so ev_cnt accumulates across the full session and TH_OPEN=2/VEL_INIT invariant
    // is preserved.  BG_WINDOW_OVR>0 overrides (UAV uses 4 for short-density gating).
    localparam BURST_WINDOW = (BG_WINDOW_OVR > 0) ? BG_WINDOW_OVR : (1 << (AW + 12));
    burst_gate #(.WINDOW(BURST_WINDOW),.TH_OPEN(BG_TH_OPEN),.TH_CLOSE(BG_TH_CLOSE)) u_bg (
        .clk(clk), .rst(rst),
        .in_valid(ds_v),
        .out_valid(bg_v)
    );

    // Delay coordinates one more cycle to align with burst gate output.
    // Tile coords (x_t_d2) kept for reference; predictor uses exact coords (ex_d3).
    reg [XW-1:0] x_t_d2 = {XW{1'b0}};
    reg [YW-1:0] y_t_d2 = {YW{1'b0}};
    reg [XW-1:0] ex_d3  = {XW{1'b0}};
    reg [YW-1:0] ey_d3  = {YW{1'b0}};
    reg signed [7:0] dir_x_d1 = 8'sd0;
    reg signed [7:0] dir_y_d1 = 8'sd0;
    always @(posedge clk) begin
        if (rst) begin
            x_t_d2   <= {XW{1'b0}};
            y_t_d2   <= {YW{1'b0}};
            ex_d3    <= {XW{1'b0}};
            ey_d3    <= {YW{1'b0}};
            dir_x_d1 <= 8'sd0;
            dir_y_d1 <= 8'sd0;
        end else begin
            x_t_d2   <= x_t_d1;
            y_t_d2   <= y_t_d1;
            ex_d3    <= ex_d2;
            ey_d3    <= ey_d2;
            dir_x_d1 <= dir_x;
            dir_y_d1 <= dir_y;
        end
    end

    //=========================================================================
    // Stage 6: α-β Predictor (+6 cycles)
    // Uses exact event pixel coords (ex_d3/ey_d3) for sub-tile position accuracy.
    // Direction (dir_x_d1/dir_y_d1) from Reichardt gives velocity hint.
    // NTRACK=1: single instance. NTRACK>1: tracker_pool with routing.
    //=========================================================================
    // TILE_STEP_PX: pixel width of one tile, used for cold-start velocity pre-load.
    localparam TILE_STEP_PX = 1 << (XW - AW/2);  // 64 for AW=8,XW=10
    // VEL_SAT: velocity saturation limit = 2× tile width, giving headroom for acceleration.
    // Scales with AW so AW=6 (tile=128px) gets VEL_SAT=256 instead of the hardcoded 64.
    localparam VEL_SAT = TILE_STEP_PX * 2;

    generate
        if (NTRACK == 1) begin : g_single
            wire [1:0] tid_unused;
            ab_predictor #(
                .XW(XW), .YW(YW), .PW(PW),
                .VEL_INIT(TILE_STEP_PX),
                .VEL_SAT_MAX(VEL_SAT)
            ) u_ab (
                .clk(clk), .rst(rst), .soft_rst(1'b0),
                .in_valid(bg_v),
                .in_x(ex_d3), .in_y(ey_d3),
                .dir_x(dir_x_d1), .dir_y(dir_y_d1),
                .out_valid(pred_valid), .x_hat(x_hat), .y_hat(y_hat)
            );
            assign track_id = 2'b00;
        end else begin : g_pool
            tracker_pool #(
                .XW(XW), .YW(YW), .PW(PW),
                .N(NTRACK), .IDW(2),
                .ASSIGN_TH(ASSIGN_TH),
                .COAST_TIMEOUT(COAST_TIMEOUT),
                .VEL_INIT(TILE_STEP_PX),
                .VEL_SAT_MAX(VEL_SAT)
            ) u_pool (
                .clk(clk), .rst(rst),
                .in_valid(bg_v),
                .in_x(ex_d3), .in_y(ey_d3),
                .dir_x(dir_x_d1), .dir_y(dir_y_d1),
                .out_valid(pred_valid), .x_hat(x_hat), .y_hat(y_hat),
                .track_id(track_id)
            );
        end
    endgenerate

    //=========================================================================
    // Confidence Scoring (parallel to predictor)
    // Combines event rate and direction magnitude
    //=========================================================================
conf_gate u_conf (
    .clk(clk), .rst(rst),
    .in_valid(ds_v), .dir_x(dir_x), .dir_y(dir_y),
    .out_valid(conf_valid), .conf(conf)
);

`ifdef LIBELLULA_STAGE_DIAG
    integer diag_fd;
    reg [1023:0] diag_path;
    integer diag_ev_count = 0;
    integer diag_lif_spikes = 0;
    integer diag_delay_hits = 0;
    integer diag_reichardt = 0;
    integer diag_burst = 0;
    integer diag_pred = 0;
    integer diag_cycle = 0;
    integer first_ev_cycle = -1;
    integer first_lif_cycle = -1;
    integer first_delay_cycle = -1;
    integer first_reichardt_cycle = -1;
    integer first_burst_cycle = -1;
    integer first_pred_cycle = -1;
    initial begin
        diag_path = "diagnostics/out/stage_diag.log";
        void'($value$plusargs("STAGE_OUT=%s", diag_path));
        diag_fd = $fopen(diag_path, "w");
        if (diag_fd == 0)
            $display("WARN: failed to open stage diag log %0s", diag_path);
    end
    always @(posedge clk) begin
        if (rst) diag_cycle <= 0;
        else diag_cycle <= diag_cycle + 1;
        if (!rst && ev_v) begin
            diag_ev_count <= diag_ev_count + 1;
            if (first_ev_cycle < 0) first_ev_cycle <= diag_cycle;
        end
        if (!rst && lif_v) begin
            diag_lif_spikes <= diag_lif_spikes + 1;
            if (first_lif_cycle < 0) first_lif_cycle <= diag_cycle;
        end
        if (!rst && (v_e|v_w|v_n|v_s|v_ne|v_nw|v_se|v_sw)) begin
            diag_delay_hits <= diag_delay_hits + 1;
            if (first_delay_cycle < 0) first_delay_cycle <= diag_cycle;
        end
        if (!rst && ds_v) begin
            diag_reichardt <= diag_reichardt + 1;
            if (first_reichardt_cycle < 0) first_reichardt_cycle <= diag_cycle;
        end
        if (!rst && bg_v) begin
            diag_burst <= diag_burst + 1;
            if (first_burst_cycle < 0) first_burst_cycle <= diag_cycle;
        end
        if (!rst && pred_valid) begin
            diag_pred <= diag_pred + 1;
            if (first_pred_cycle < 0) first_pred_cycle <= diag_cycle;
        end
    end
    final begin
        if (diag_fd != 0) begin
            $fwrite(diag_fd,
                "PHASE2_STAGE events=%0d lif=%0d delay=%0d reichardt=%0d burst=%0d pred=%0d first_ev=%0d first_lif=%0d first_delay=%0d first_reichardt=%0d first_burst=%0d first_pred=%0d\n",
                diag_ev_count, diag_lif_spikes, diag_delay_hits,
                diag_reichardt, diag_burst, diag_pred,
                first_ev_cycle, first_lif_cycle, first_delay_cycle,
                first_reichardt_cycle, first_burst_cycle, first_pred_cycle);
            $fclose(diag_fd);
        end else begin
            $display("PHASE2_STAGE events=%0d lif=%0d delay=%0d reichardt=%0d burst=%0d pred=%0d first_ev=%0d first_lif=%0d first_delay=%0d first_reichardt=%0d first_burst=%0d first_pred=%0d",
                diag_ev_count, diag_lif_spikes, diag_delay_hits,
                diag_reichardt, diag_burst, diag_pred,
                first_ev_cycle, first_lif_cycle, first_delay_cycle,
                first_reichardt_cycle, first_burst_cycle, first_pred_cycle);
        end
    end
`endif

endmodule

`default_nettype wire
