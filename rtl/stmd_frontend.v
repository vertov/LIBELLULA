`timescale 1ns/1ps
`default_nettype none
// stmd_frontend — per-pixel front end of the small-target detector (v26).
//
// Implements, bit for bit, the four front-end functions of the fixed-point C
// reference stmd/cref/stmd_ref.c (fe_noise, fe_glare, fe_baf, fe_habit):
//
//   stage 8  global background-rate estimate -> activity-filter window,
//            support count and candidate threshold (3 lookup tables)
//   stage 7  slow per-region glare accumulator -> glare mute flag
//   stage 1  per-pixel activity filter: count of 8 neighbours seen within
//            T_ba_eff ms, pass if >= n_sup
//   stage 2  per-pixel leaky polarity-reversal count -> habituated flag
//
// Number formats follow stmd/docs/CREF.md: 16-bit ms timestamps with a
// valid bit, ages saturating at 4095 ms, Q12.4 accumulators, 128-entry Q16
// decay tables indexed by whole buckets elapsed since a reference time that
// advances by the buckets applied (telescoping decay).
//
// Constants and tables come from the include file FE_PARAMS and the hex
// files written by `stmd_ref --dump-tables`, so the RTL cannot drift from
// the C model's arithmetic.
//
// Timing: one event at a time, 12 cycles per event (1 setup/read, 1 glare
// write-back, 8 neighbour reads, 1 own-pixel update, 1 output). in_ready is
// high in IDLE. At 200 MHz this is ~16 M events/s, well above DVS peak rates.
//
// Memories are declared as reg arrays with asynchronous read. For an FPGA
// the per-pixel arrays map to block RAM (one read, one write port); the
// neighbour scan is already serialised so a single-port RAM suffices.
//
// Known simplifications, documented rather than hidden:
//   - `/ BUCKET` and `/ RATE_STEP` are divisions by constants. A real
//     implementation would use a reciprocal multiply or a power-of-two
//     bucket; the C model and this RTL use exact integer division so that
//     the table semantics are identical.
//   - 16-bit ms timestamps wrap after 65.5 s; a deployment needs a periodic
//     sweep that invalidates stale pixels (as the LIF scan does). Not
//     implemented here; sequences in the benches are < 65 s.
//   - Per-pixel storage: 16+1 (last event) + 16+16+2 (flip count, its
//     reference time, last polarity + valid) = 51 bits/pixel.
module stmd_frontend #(
    parameter W = 346,
    parameter H = 260,
    parameter XW = 9,               // ceil(log2(W))
    parameter YW = 9,               // ceil(log2(H))
    parameter FE_PARAMS  = "fe_params.vh",
    parameter LUT_FLIP   = "lut_flip.hex",
    parameter LUT_G      = "lut_g.hex",
    parameter LUT_N      = "lut_n.hex",
    parameter TBA_LUT    = "tba_lut.hex",
    parameter NSUP_LUT   = "nsup_lut.hex",
    parameter THETA_LUT  = "theta_lut.hex"
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          in_valid,
    output wire          in_ready,
    input  wire [XW-1:0] in_x,
    input  wire [YW-1:0] in_y,
    input  wire          in_pol,
    input  wire [15:0]   in_t_ms,
    output reg           out_valid,
    output reg  [XW-1:0] out_x,
    output reg  [YW-1:0] out_y,
    output reg           out_pol,
    output reg  [15:0]   out_t_ms,
    output reg           out_baf,
    output reg           out_hab,
    output reg           out_glare,
    output reg  [15:0]   out_theta_q4   // candidate threshold for the next stage
);
    `include "fe_params.vh"

    localparam integer NPIX = W * H;
    localparam integer GW   = (W + G_CELL - 1) / G_CELL;
    localparam integer GH   = (H + G_CELL - 1) / G_CELL;
    localparam integer NG   = GW * GH;
    localparam [11:0] AGE_MAX = 12'd4095;

    // ---- tables ----------------------------------------------------------
    reg [15:0] lut_flip [0:127];
    reg [15:0] lut_g    [0:127];
    reg [15:0] lut_n    [0:127];
    reg [15:0] tba_lut  [0:63];
    reg [7:0]  nsup_lut [0:63];
    reg [15:0] theta_lut[0:63];
    initial begin
        $readmemh(LUT_FLIP, lut_flip);
        $readmemh(LUT_G, lut_g);
        $readmemh(LUT_N, lut_n);
        $readmemh(TBA_LUT, tba_lut);
        $readmemh(NSUP_LUT, nsup_lut);
        $readmemh(THETA_LUT, theta_lut);
    end

    // ---- state -----------------------------------------------------------
    reg [15:0] last_any   [0:NPIX-1];
    reg        any_valid  [0:NPIX-1];
    reg [15:0] flips      [0:NPIX-1];
    reg [15:0] flip_t     [0:NPIX-1];
    reg        q_valid    [0:NPIX-1];
    reg        last_q     [0:NPIX-1];
    reg [15:0] g_acc      [0:NG-1];
    reg [15:0] g_t        [0:NG-1];
    reg        g_valid    [0:NG-1];
    reg [23:0] ng_acc;
    reg [15:0] ng_t;
    reg        ng_valid;

`ifndef SYNTHESIS
    // Simulation-only initialisation of the valid bits. In hardware the
    // valid bits must be cleared by a reset sweep (one pixel per cycle, as
    // the LIF scan does) before events are accepted.
    integer i;
    initial begin
        for (i = 0; i < NPIX; i = i + 1) begin
            any_valid[i] = 1'b0; q_valid[i] = 1'b0; last_q[i] = 1'b0;
            last_any[i] = 16'd0; flips[i] = 16'd0; flip_t[i] = 16'd0;
        end
        for (i = 0; i < NG; i = i + 1) begin
            g_valid[i] = 1'b0; g_acc[i] = 16'd0; g_t[i] = 16'd0;
        end
    end
`endif

    // ---- helpers (pure functions, mirror the C) --------------------------
    /* verilator lint_off BLKSEQ */
    // saturating age in ms
    function [11:0] age_ms;
        input [15:0] now; input [15:0] last; input valid;
        reg [15:0] d;
        begin
            d = now - last;
            age_ms = (!valid) ? AGE_MAX : (d > 16'd4095 ? AGE_MAX : d[11:0]);
        end
    endfunction

    // decay index and advance: idx = min(age,4095)/bucket ; returns {zero, idx, advance}
    function [6:0] decay_idx;        // 7 bits: 0..127 valid, >=128 -> returns 127 with zero flag separately
        input [15:0] now; input [15:0] tref; input [15:0] bucket;
        reg [15:0] d; reg [15:0] q;
        begin
            d = now - tref;
            if (d > 16'd4095) d = 16'd4095;
            q = d / bucket;
            decay_idx = (q >= 16'd128) ? 7'd127 : q[6:0];
        end
    endfunction
    function decay_zero;
        input [15:0] now; input [15:0] tref; input [15:0] bucket;
        reg [15:0] d; reg [15:0] q;
        begin
            d = now - tref;
            if (d > 16'd4095) d = 16'd4095;
            q = d / bucket;
            decay_zero = (q >= 16'd128);
        end
    endfunction

    /* verilator lint_on BLKSEQ */

    // ---- per-event datapath registers ------------------------------------
    reg [XW-1:0] ex; reg [YW-1:0] ey; reg epol; reg [15:0] enow;
    reg [15:0] tba_eff; reg [7:0] nsup; reg [15:0] theta_eff;
    reg        glare_r;
    reg [3:0]  sup;
    reg [3:0]  step;                 // neighbour index 0..7
    reg [2:0]  st;
    localparam [2:0] S_IDLE = 3'd0, S_SETUP = 3'd1, S_GLARE = 3'd2, S_NB = 3'd3, S_OWN = 3'd4, S_OUT = 3'd5;
    // registered copies of memory words (read in SETUP, used in GLARE/OWN) so
    // that no combinational block reads the large arrays
    reg [15:0] g_acc_r, g_t_r; reg g_v_r;
    reg [15:0] f_r, f_t_r; reg f_qv_r, f_lq_r;

    assign in_ready = (st == S_IDLE);

    // neighbour offsets, 8-neighbourhood without centre, same order as C (dy outer, dx inner)
    reg signed [1:0] ndx, ndy;
    always @(*) begin
        case (step)
            4'd0: begin ndy = -2'sd1; ndx = -2'sd1; end
            4'd1: begin ndy = -2'sd1; ndx =  2'sd0; end
            4'd2: begin ndy = -2'sd1; ndx =  2'sd1; end
            4'd3: begin ndy =  2'sd0; ndx = -2'sd1; end
            4'd4: begin ndy =  2'sd0; ndx =  2'sd1; end
            4'd5: begin ndy =  2'sd1; ndx = -2'sd1; end
            4'd6: begin ndy =  2'sd1; ndx =  2'sd0; end
            default: begin ndy = 2'sd1; ndx = 2'sd1; end
        endcase
    end
    wire signed [XW+1:0] nx = $signed({2'b00, ex}) + $signed({{XW{ndx[1]}}, ndx});
    wire signed [YW+1:0] ny = $signed({2'b00, ey}) + $signed({{YW{ndy[1]}}, ndy});
    wire nb_in = (nx >= 0) && (nx < $signed({2'b00, W[XW-1:0]})) && (ny >= 0) && (ny < $signed({2'b00, H[YW-1:0]}));
    wire [31:0] nx_u = {{(32-XW){1'b0}}, nx[XW-1:0]};
    wire [31:0] ny_u = {{(32-YW){1'b0}}, ny[YW-1:0]};
    wire [31:0] ex_u = {{(32-XW){1'b0}}, ex};
    wire [31:0] ey_u = {{(32-YW){1'b0}}, ey};
    wire [31:0] nb_addr  = ny_u * W + nx_u;
    wire [31:0] own_addr = ey_u * W + ex_u;
    wire [31:0] g_addr   = (ey_u / G_CELL) * GW + (ex_u / G_CELL);

    // ---- noise: next-state computed combinationally from current regs -----
    reg  [23:0] ng_next; reg [15:0] ng_t_next; reg [6:0] ng_idx; reg ng_zero; reg [39:0] ng_mul; reg [23:0] ng_dec;
    reg  [23:0] rate_q; reg [5:0] rate_idx;
    always @(*) begin
        ng_idx  = decay_idx(enow, ng_t, BUCKET_N);
        ng_zero = decay_zero(enow, ng_t, BUCKET_N);
        ng_mul  = ng_acc * lut_n[ng_idx];
        ng_dec  = ng_zero ? 24'd0 : ng_mul[39:16];
        if (!ng_valid) begin ng_dec = 24'd0; ng_t_next = enow; end
        else if (ng_zero) ng_t_next = enow;
        else ng_t_next = ng_t + {9'd0, ng_idx} * BUCKET_N;
        ng_next = (ng_dec > 24'hFFFFEF) ? 24'hFFFFFF : ng_dec + 24'd16;
        rate_q  = ng_next / RATE_STEP;
        rate_idx = (rate_q >= 24'd64) ? 6'd63 : rate_q[5:0];
    end

    // ---- glare: next state from the registered word ----------------------
    reg [6:0] g_idx; reg g_zero; reg [31:0] g_mul; reg [16:0] g_dec; reg [15:0] g_next; reg [15:0] g_t_next;
    always @(*) begin
        g_idx  = decay_idx(enow, g_t_r, BUCKET_G);
        g_zero = decay_zero(enow, g_t_r, BUCKET_G);
        g_mul  = g_acc_r * lut_g[g_idx];
        g_dec  = g_zero ? 17'd0 : {1'b0, g_mul[31:16]};
        if (!g_v_r) begin g_dec = 17'd0; g_t_next = enow; end
        else if (g_zero) g_t_next = enow;
        else g_t_next = g_t_r + {9'd0, g_idx} * BUCKET_G;
        g_next = (g_dec + 17'd16 > 17'd65535) ? 16'd65535 : g_dec[15:0] + 16'd16;
    end

    // ---- habituation: next state (own pixel) from the registered word ----
    reg [6:0] f_idx; reg f_zero; reg [31:0] f_mul; reg [16:0] f_dec; reg [16:0] f_sum; reg [15:0] f_next; reg [15:0] f_t_next;
    always @(*) begin
        f_idx  = decay_idx(enow, f_t_r, BUCKET_FLIP);
        f_zero = decay_zero(enow, f_t_r, BUCKET_FLIP);
        f_mul  = f_r * lut_flip[f_idx];
        f_dec  = f_zero ? 17'd0 : {1'b0, f_mul[31:16]};
        if (!f_qv_r) begin f_dec = 17'd0; f_t_next = enow; end
        else if (f_zero) f_t_next = enow;
        else f_t_next = f_t_r + {9'd0, f_idx} * BUCKET_FLIP;
        f_sum  = f_dec + ((f_qv_r && (f_lq_r != epol)) ? 17'd16 : 17'd0);
        f_next = (f_sum > 17'd65535) ? 16'd65535 : f_sum[15:0];
    end

    // ---- FSM -------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; out_valid <= 1'b0; step <= 4'd0; sup <= 4'd0;
            ng_acc <= 24'd0; ng_t <= 16'd0; ng_valid <= 1'b0;
            ex <= {XW{1'b0}}; ey <= {YW{1'b0}}; epol <= 1'b0; enow <= 16'd0;
            g_acc_r <= 16'd0; g_t_r <= 16'd0; g_v_r <= 1'b0; f_r <= 16'd0; f_t_r <= 16'd0; f_qv_r <= 1'b0; f_lq_r <= 1'b0;
            tba_eff <= T_BA_MS; nsup <= 8'd1; theta_eff <= 16'd0; glare_r <= 1'b0;
            out_x <= {XW{1'b0}}; out_y <= {YW{1'b0}}; out_pol <= 1'b0; out_t_ms <= 16'd0;
            out_baf <= 1'b0; out_hab <= 1'b0; out_glare <= 1'b0; out_theta_q4 <= 16'd0;
        end else begin
            out_valid <= 1'b0;
            case (st)
                S_IDLE: if (in_valid) begin
                    ex <= in_x; ey <= in_y; epol <= in_pol; enow <= in_t_ms;
                    st <= S_SETUP;
                end
                S_SETUP: begin
                    // stage 8: global rate and tables
                    if (USE_NOISE) begin
                        ng_acc <= ng_next; ng_t <= ng_t_next; ng_valid <= 1'b1;
                        tba_eff <= tba_lut[rate_idx]; nsup <= nsup_lut[rate_idx]; theta_eff <= theta_lut[rate_idx];
                    end else begin
                        tba_eff <= T_BA_MS; nsup <= 8'd1; theta_eff <= theta_lut[0];
                    end
                    // memory reads for the glare region and the own pixel
                    g_acc_r <= g_acc[g_addr]; g_t_r <= g_t[g_addr]; g_v_r <= g_valid[g_addr];
                    f_r <= flips[own_addr]; f_t_r <= flip_t[own_addr]; f_qv_r <= q_valid[own_addr]; f_lq_r <= last_q[own_addr];
                    sup <= 4'd0; step <= 4'd0;
                    st <= S_GLARE;
                end
                S_GLARE: begin
                    // stage 7: glare region accumulator write-back
                    if (USE_GLARE) begin
                        g_acc[g_addr] <= g_next; g_t[g_addr] <= g_t_next; g_valid[g_addr] <= 1'b1;
                        glare_r <= (g_next > G_THR_Q4);
                    end else glare_r <= 1'b0;
                    st <= S_NB;
                end
                S_NB: begin
                    // stage 1: neighbour support count (uses tba_eff registered in SETUP)
                    if (nb_in && (age_ms(enow, last_any[nb_addr], any_valid[nb_addr]) <= tba_eff[11:0] || (tba_eff > 16'd4095)))
                        sup <= sup + 4'd1;
                    if (step == 4'd7) st <= S_OWN; else step <= step + 4'd1;
                end
                S_OWN: begin
                    // stage 1 write-back and stage 2 habituation (own pixel)
                    last_any[own_addr] <= enow; any_valid[own_addr] <= 1'b1;
                    flips[own_addr] <= f_next; flip_t[own_addr] <= f_t_next;
                    q_valid[own_addr] <= 1'b1; last_q[own_addr] <= epol;
                    out_hab <= (USE_HAB != 0) && (f_next > F_MAX_Q4);
                    st <= S_OUT;
                end
                default: begin   // S_OUT
                    out_valid <= 1'b1;
                    out_x <= ex; out_y <= ey; out_pol <= epol; out_t_ms <= enow;
                    out_baf <= ({4'd0, sup} >= nsup);
                    out_glare <= glare_r;
                    out_theta_q4 <= theta_eff;
                    st <= S_IDLE;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
