`timescale 1ns/1ps
`default_nettype none
// stmd_backend — stages 3..6 of the small-target detector (v27).
//
// Mirrors, bit for bit, process() in stmd/cref/stmd_ref.c after the front
// end: ESTMD polarity correlation, cell accumulators with centre-surround
// inhibition, the tracker pool (alpha-beta update, confirmation,
// stationarity) and event labelling. Consumes the front end's flags (baf,
// habituated, glare, theta_eff) and produces the per-event target label
// together with a record for every update of a confirmed, moving track.
//
// Number formats (stmd/docs/CREF.md): accumulators Q12.4 with 128-entry Q16
// decay tables and a telescoping reference time; positions Q8 px (signed
// 32); velocities Q16 px/ms (signed 32); squared distances Q16 px^2 (signed
// 64). The velocity measurement (dx * 256) / dt_ms uses a 32-step restoring
// divider; the quotient truncates toward zero as C does.
//
// Cycles per event, selected configuration: 2 (ESTMD, NBR=0) + 5 (cells) +
// 2*81 (ring, SR=4) + 1 + 8 (nearest track) + ~75 (update, two divisions) or
// 9 (spawn) + 8 (labelling) + 1 ~ 265 worst case, ~20 for an event that
// does not pass the activity filter.
//
// Deployability: after reset a clearing sweep runs before in_ready; in idle
// cycles one pixel's polarity timestamps and one cell's accumulators are
// expired when older than 4095 ms and one track is retired when older than
// T_DEAD, so 16-bit timestamps never alias provided the sweep covers every
// entry within ~60 s (1.3 M idle cycles at 346x260).
module stmd_backend #(
    parameter W = 346,
    parameter H = 260,
    parameter XW = 9,
    parameter YW = 9,
    parameter LUT_ACC = "lut_acc.hex"
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          in_valid,
    output wire          in_ready,
    input  wire [XW-1:0] in_x,
    input  wire [YW-1:0] in_y,
    input  wire          in_pol,
    input  wire [15:0]   in_t_ms,
    input  wire          in_baf,
    input  wire          in_hab,
    input  wire          in_glare,
    input  wire [15:0]   in_theta_q4,
    input  wire [15:0]   now_ms,
    output reg           out_valid,
    output reg           out_label,
    output reg           out_cand,
    output reg           trk_valid,
    output reg  [31:0]   trk_uid,
    output reg  signed [31:0] trk_x_q8,
    output reg  signed [31:0] trk_y_q8
);
    `include "fe_params.vh"

    localparam integer NPIX  = W * H;
    localparam integer NC    = HC * WC;
    localparam integer NBW   = 2 * NBR + 1;
    localparam integer NNB   = NBW * NBW;
    localparam integer RR    = (USE_SUR != 0) ? SR : 1;
    localparam integer RW    = 2 * RR + 1;
    localparam integer NRING = RW * RW;
    localparam integer DIVN  = 32;      // numerator bits: |dx| < 2^17 Q8 px, * 256 < 2^25
    localparam integer TW    = (NT > 1) ? $clog2(NT) : 1;   // track index width
    localparam [TW-1:0] T0 = 0, T1 = 1;
    localparam [TW-1:0] TLAST = T0 - T1 + NT[TW-1:0];

    reg [15:0] lut_acc [0:127];
    initial $readmemh(LUT_ACC, lut_acc);

    // ---- memories ----------------------------------------------------------
    reg [15:0] pol_t [0:2*NPIX-1];     // [pol*NPIX + y*W + x]
    reg        pol_v [0:2*NPIX-1];
    reg [15:0] r_acc [0:NC-1]; reg [15:0] r_t [0:NC-1]; reg r_v [0:NC-1];
    reg [15:0] a_acc [0:NC-1]; reg [15:0] a_t [0:NC-1]; reg a_v [0:NC-1];

`ifndef SYNTHESIS
    integer ii;
    initial begin
        for (ii = 0; ii < 2 * NPIX; ii = ii + 1) begin pol_v[ii] = 1'b0; pol_t[ii] = 16'd0; end
        for (ii = 0; ii < NC; ii = ii + 1) begin
            r_v[ii] = 1'b0; r_acc[ii] = 16'd0; r_t[ii] = 16'd0; a_v[ii] = 1'b0; a_acc[ii] = 16'd0; a_t[ii] = 16'd0;
        end
    end
`endif

    // ---- track registers ---------------------------------------------------
    reg tr_on [0:NT-1]; reg tr_conf [0:NT-1]; reg tr_stat [0:NT-1];
    reg signed [31:0] tr_x [0:NT-1]; reg signed [31:0] tr_y [0:NT-1];
    reg signed [31:0] tr_vx [0:NT-1]; reg signed [31:0] tr_vy [0:NT-1];
    reg [15:0] tr_tu [0:NT-1]; reg [15:0] tr_at [0:NT-1]; reg [15:0] tr_t0 [0:NT-1]; reg [15:0] tr_ct [0:NT-1];
    reg signed [31:0] tr_ax [0:NT-1]; reg signed [31:0] tr_ay [0:NT-1];
    reg signed [31:0] tr_x0 [0:NT-1]; reg signed [31:0] tr_y0 [0:NT-1];
    reg signed [31:0] tr_cx [0:NT-1]; reg signed [31:0] tr_cy [0:NT-1];
    reg [15:0] tr_hits [0:NT-1];
    reg signed [63:0] tr_dmax2 [0:NT-1];
    reg [31:0] tr_uid [0:NT-1];
    reg [31:0] uid_next;

    // ---- helpers -----------------------------------------------------------
    /* verilator lint_off BLKSEQ */
    function [6:0] decay_idx;
        input [15:0] now; input [15:0] tref; input [3:0] shift;
        reg [15:0] d; reg [15:0] q;
        begin d = now - tref; q = d >> shift; decay_idx = (q >= 16'd128) ? 7'd127 : q[6:0]; end
    endfunction
    function decay_zero;
        input [15:0] now; input [15:0] tref; input [3:0] shift;
        reg [15:0] d; reg [15:0] q;
        begin d = now - tref; q = d >> shift; decay_zero = (d > 16'd4095) || (q >= 16'd128); end
    endfunction
    function [15:0] acc_peek;          // acc_read(): decayed value of a valid word, else 0
        input [15:0] v; input [15:0] now; input [15:0] tref; input valid;
        reg [31:0] m; reg [6:0] idx;
        begin
            idx = decay_idx(now, tref, SHIFT_ACC);
            m = v * lut_acc[idx];
            acc_peek = (!valid || decay_zero(now, tref, SHIFT_ACC)) ? 16'd0 : m[31:16];
        end
    endfunction
    function signed [63:0] sx32;      // sign-extend 32 -> 64
        input signed [31:0] v;
        begin sx32 = {{32{v[31]}}, v}; end
    endfunction
    function [63:0] abs64;
        input signed [63:0] v;
        begin abs64 = v[63] ? -v : v; end
    endfunction
    /* verilator lint_on BLKSEQ */

    // ---- event registers ---------------------------------------------------
    reg [XW-1:0] ex; reg [YW-1:0] ey; reg epol; reg [15:0] enow;
    reg ebaf, ehab, eglare; reg [15:0] etheta;
    reg resp; reg [15:0] wgt; reg corr; reg cand; reg pred;
    reg signed [31:0] xq, yq;

    wire [31:0] ex_u = {{(32-XW){1'b0}}, ex};
    wire [31:0] ey_u = {{(32-YW){1'b0}}, ey};
    wire [31:0] own_addr = ey_u * W + ex_u;
    wire [31:0] cy = ey_u / CELL;
    wire [31:0] cx = ex_u / CELL;
    wire [31:0] ci = cy * WC + cx;

    // neighbour (ESTMD) and ring iteration
    reg [7:0] it;
    wire signed [31:0] it_s = $signed({24'd0, it});
    wire signed [31:0] nb_dy = it_s / NBW - NBR;
    wire signed [31:0] nb_dx = it_s % NBW - NBR;
    wire signed [31:0] nby = $signed(ey_u) + nb_dy;
    wire signed [31:0] nbx = $signed(ex_u) + nb_dx;
    wire nb_in = (nby >= 0) && (nby < H) && (nbx >= 0) && (nbx < W);
    wire [31:0] nb_addr = (epol ? 32'd0 : NPIX) + nby * W + nbx;     // opposite polarity
    wire signed [31:0] rg_dy = it_s / RW - RR;
    wire signed [31:0] rg_dx = it_s % RW - RR;
    wire signed [31:0] rgy = $signed(cy) + rg_dy;
    wire signed [31:0] rgx = $signed(cx) + rg_dx;
    wire rg_in = (rgy >= 0) && (rgy < HC) && (rgx >= 0) && (rgx < WC);
    wire rg_centre = (rg_dy >= -1) && (rg_dy <= 1) && (rg_dx >= -1) && (rg_dx <= 1);
    wire [31:0] rg_addr = rgy * WC + rgx;

    // registered memory words
    reg [15:0] w_acc, w_t; reg w_v; reg [15:0] b_w;      // read-modify-write of A / R
    reg [15:0] rr_acc, rr_t; reg rr_v;                   // ring R word
    reg [15:0] ra_acc, ra_t; reg ra_v;                   // ring A word
    reg rg_centre_r, rg_in_r;
    reg [15:0] pw_t; reg pw_v;                           // ESTMD neighbour word
    wire [15:0] pw_d = enow - pw_t;
    wire [11:0] pw_age = (!pw_v || pw_d > 16'd4095) ? 12'd4095 : pw_d[11:0];

    // surround sums
    reg [63:0] rc, rs, as_; reg [7:0] nc, ns;
    wire [63:0] sc_lhs = rc * {56'd0, ns} * 64'd16 - ({48'd0, K_INH_Q4} * rs + {48'd0, K_ACT_Q4} * as_) * {56'd0, nc};
    wire [63:0] sc_rhs = {48'd0, etheta} * {56'd0, ns} * 64'd16;
    wire cand_sur  = $signed(sc_lhs) >= $signed(sc_rhs);
    wire cand_ring = rc >= {48'd0, etheta};

    // accumulator bump: acc_bump() on the registered word
    reg [6:0] b_idx; reg b_zero; reg [31:0] b_mul; reg [16:0] b_sum; reg [15:0] b_next; reg [15:0] b_t_next;
    always @(*) begin
        b_idx  = decay_idx(enow, w_t, SHIFT_ACC);
        b_zero = decay_zero(enow, w_t, SHIFT_ACC);
        b_mul  = w_acc * lut_acc[b_idx];
        if (!w_v || b_zero) begin b_sum = {1'b0, b_w}; b_t_next = enow; end
        else begin b_sum = {1'b0, b_mul[31:16]} + {1'b0, b_w}; b_t_next = w_t + ({9'd0, b_idx} << SHIFT_ACC); end
        b_next = (b_sum > 17'd65535) ? 16'd65535 : b_sum[15:0];
    end

    // ---- tracker datapath (combinational on track k) -----------------------
    reg [TW-1:0] k, best; reg signed [63:0] bd; reg found;
    wire [15:0] age_tu_k = enow - tr_tu[k];
    wire [15:0] age_at_k = enow - tr_at[k];
    wire [15:0] age_t0_k = enow - tr_t0[k];
    wire [15:0] age_ct_k = enow - tr_ct[k];
    wire signed [63:0] dt_k = $signed({48'd0, age_tu_k});
    wire signed [63:0] px_k = sx32(tr_x[k]) + ((sx32(tr_vx[k]) * dt_k) >>> 8);
    wire signed [63:0] py_k = sx32(tr_y[k]) + ((sx32(tr_vy[k]) * dt_k) >>> 8);
    wire signed [63:0] ddx = sx32(xq) - px_k;
    wire signed [63:0] ddy = sx32(yq) - py_k;
    wire signed [63:0] d2_k = ddx * ddx + ddy * ddy;
    wire hit_k = tr_on[k] && (d2_k < bd);
    wire signed [63:0] upd_x = px_k + (($signed({48'd0, ALPHA_Q8}) * ddx) >>> 8);
    wire signed [63:0] upd_y = py_k + (($signed({48'd0, ALPHA_Q8}) * ddy) >>> 8);
    // after the position update (B_UPD has written tr_x/tr_y)
    wire signed [31:0] dax = tr_x[k] - tr_ax[k];
    wire signed [31:0] day = tr_y[k] - tr_ay[k];
    wire signed [63:0] dx0 = sx32(tr_x[k]) - sx32(tr_x0[k]);
    wire signed [63:0] dy0 = sx32(tr_y[k]) - sx32(tr_y0[k]);
    wire signed [63:0] dxc = sx32(tr_x[k]) - sx32(tr_cx[k]);
    wire signed [63:0] dyc = sx32(tr_y[k]) - sx32(tr_cy[k]);
    wire signed [63:0] dd2 = dx0 * dx0 + dy0 * dy0;
    wire signed [63:0] ds2 = dxc * dxc + dyc * dyc;
    wire signed [63:0] dmax2_new = (dd2 > tr_dmax2[k]) ? dd2 : tr_dmax2[k];
    wire stat_due  = (T_STAT_MS != 12'd0) && (age_ct_k >= {4'd0, T_STAT_MS});
    wire stat_new  = stat_due ? (ds2 < $signed({16'd0, D_STAT2_Q16})) : tr_stat[k];
    wire conf_new  = tr_conf[k] || (tr_hits[k] >= H_MIN && age_t0_k >= {4'd0, T_CONF_MS} && dmax2_new >= $signed({16'd0, D_MIN2_Q16}));
    // velocity
    reg signed [63:0] vxm, vym;
    wire signed [63:0] vx_upd = sx32(tr_vx[k]) + (($signed({48'd0, VBETA_Q8}) * (vxm - sx32(tr_vx[k]))) >>> 8);
    wire signed [63:0] vy_upd = sx32(tr_vy[k]) + (($signed({48'd0, VBETA_Q8}) * (vym - sx32(tr_vy[k]))) >>> 8);
    // divider
    reg [5:0] div_cnt; reg [63:0] div_rem, div_q, div_n; reg [15:0] div_d; reg div_neg;
    wire [63:0] div_sh = {div_rem[62:0], div_n[DIVN-1]};
    wire div_ge = div_sh >= {48'd0, div_d};
    // spawn
    reg [TW-1:0] slot; reg slot_free; reg [15:0] slot_age;
    // labelling
    wire signed [63:0] lab_ex = $signed({40'd0, R_LAB_Q8}) + (((($signed({48'd0, K_VLAB_Q8}) * $signed(abs64(sx32(tr_vx[k])))) >>> 8) * $signed({52'd0, T_LAB_MS})) >>> 8);
    wire signed [63:0] lab_ey = $signed({40'd0, R_LAB_Q8}) + (((($signed({48'd0, K_VLAB_Q8}) * $signed(abs64(sx32(tr_vy[k])))) >>> 8) * $signed({52'd0, T_LAB_MS})) >>> 8);
    wire lab_hit = tr_on[k] && tr_conf[k] && !tr_stat[k] && (age_tu_k <= {4'd0, T_LAB_MS}) &&
                   ($signed(abs64(ddx)) <= lab_ex) && ($signed(abs64(ddy)) <= lab_ey);

    // ---- sweeps ------------------------------------------------------------
    reg [31:0] sw_ptr, csw_ptr;
    wire [15:0] swp_age0 = now_ms - pol_t[sw_ptr];
    wire [15:0] swp_age1 = now_ms - pol_t[NPIX + sw_ptr];
    wire [15:0] swr_age  = now_ms - r_t[csw_ptr];
    wire [15:0] swa_age  = now_ms - a_t[csw_ptr];
    wire [15:0] swt_age  = now_ms - tr_tu[k];

    // ---- FSM ---------------------------------------------------------------
    reg [4:0] st;
    localparam [4:0] B_RESET = 5'd0, B_IDLE = 5'd1, B_ESTMD_RD = 5'd2, B_ESTMD_CHK = 5'd3, B_POLW = 5'd4,
                     B_ARD = 5'd5, B_AWR = 5'd6, B_RRD = 5'd7, B_RWR = 5'd8, B_RING_RD = 5'd9, B_RING_ACC = 5'd10,
                     B_SCORE = 5'd11, B_RETIRE = 5'd12, B_FIND = 5'd13, B_UPD = 5'd14, B_DIVX = 5'd15,
                     B_DIVX_W = 5'd16, B_DIVY_W = 5'd17, B_VEL = 5'd18, B_POST = 5'd19, B_SPAWN = 5'd20,
                     B_SPAWN_W = 5'd21, B_LABEL = 5'd22, B_OUT = 5'd23;
    assign in_ready = (st == B_IDLE);

    integer j;
    always @(posedge clk) begin
        if (rst) begin
            st <= B_RESET; out_valid <= 1'b0; trk_valid <= 1'b0; sw_ptr <= 32'd0; csw_ptr <= 32'd0; uid_next <= 32'd0;
            out_label <= 1'b0; out_cand <= 1'b0; trk_uid <= 32'd0; trk_x_q8 <= 32'sd0; trk_y_q8 <= 32'sd0;
            ex <= {XW{1'b0}}; ey <= {YW{1'b0}}; epol <= 1'b0; enow <= 16'd0; ebaf <= 1'b0; ehab <= 1'b0; eglare <= 1'b0; etheta <= 16'd0;
            resp <= 1'b0; wgt <= 16'd16; corr <= 1'b0; cand <= 1'b0; pred <= 1'b0; xq <= 32'sd0; yq <= 32'sd0; it <= 8'd0;
            w_acc <= 16'd0; w_t <= 16'd0; w_v <= 1'b0; b_w <= 16'd16;
            rr_acc <= 16'd0; rr_t <= 16'd0; rr_v <= 1'b0; ra_acc <= 16'd0; ra_t <= 16'd0; ra_v <= 1'b0;
            rg_centre_r <= 1'b0; rg_in_r <= 1'b0; pw_t <= 16'd0; pw_v <= 1'b0;
            rc <= 64'd0; rs <= 64'd0; as_ <= 64'd0; nc <= 8'd0; ns <= 8'd0;
            k <= T0; best <= T0; bd <= 64'sd0; found <= 1'b0; vxm <= 64'sd0; vym <= 64'sd0;
            div_cnt <= 6'd0; div_rem <= 64'd0; div_q <= 64'd0; div_n <= 64'd0; div_d <= 16'd0; div_neg <= 1'b0;
            slot <= T0; slot_free <= 1'b0; slot_age <= 16'd0;
            for (j = 0; j < NT; j = j + 1) begin
                tr_on[j] <= 1'b0; tr_conf[j] <= 1'b0; tr_stat[j] <= 1'b0; tr_x[j] <= 32'sd0; tr_y[j] <= 32'sd0; tr_vx[j] <= 32'sd0; tr_vy[j] <= 32'sd0;
                tr_tu[j] <= 16'd0; tr_at[j] <= 16'd0; tr_t0[j] <= 16'd0; tr_ct[j] <= 16'd0; tr_ax[j] <= 32'sd0; tr_ay[j] <= 32'sd0;
                tr_x0[j] <= 32'sd0; tr_y0[j] <= 32'sd0; tr_cx[j] <= 32'sd0; tr_cy[j] <= 32'sd0; tr_hits[j] <= 16'd0; tr_dmax2[j] <= 64'sd0; tr_uid[j] <= 32'd0;
            end
        end else begin
            out_valid <= 1'b0; trk_valid <= 1'b0;
            case (st)
                B_RESET: begin
                    pol_v[sw_ptr] <= 1'b0; pol_v[NPIX + sw_ptr] <= 1'b0;
                    if (sw_ptr < NC) begin r_v[sw_ptr] <= 1'b0; a_v[sw_ptr] <= 1'b0; end
                    if (sw_ptr == NPIX - 1) begin sw_ptr <= 32'd0; st <= B_IDLE; end else sw_ptr <= sw_ptr + 32'd1;
                end
                B_IDLE: begin
                    if (in_valid) begin
                        ex <= in_x; ey <= in_y; epol <= in_pol; enow <= in_t_ms; ebaf <= in_baf; ehab <= in_hab; eglare <= in_glare; etheta <= in_theta_q4;
                        xq <= $signed({{(32-XW-8){1'b0}}, in_x, 8'd0}); yq <= $signed({{(32-YW-8){1'b0}}, in_y, 8'd0});
                        resp <= 1'b0; wgt <= 16'd16; corr <= 1'b0; cand <= 1'b0; pred <= 1'b0; it <= 8'd0; k <= T0;
                        rc <= 64'd0; rs <= 64'd0; as_ <= 64'd0; nc <= 8'd0; ns <= 8'd0;
                        st <= (USE_ESTMD != 0) ? B_ESTMD_RD : B_POLW;
                    end else begin
                        if (pol_v[sw_ptr] && swp_age0 > 16'd4095) pol_v[sw_ptr] <= 1'b0;
                        if (pol_v[NPIX + sw_ptr] && swp_age1 > 16'd4095) pol_v[NPIX + sw_ptr] <= 1'b0;
                        sw_ptr <= (sw_ptr == NPIX - 1) ? 32'd0 : sw_ptr + 32'd1;
                        if (r_v[csw_ptr] && swr_age > 16'd4095) r_v[csw_ptr] <= 1'b0;
                        if (a_v[csw_ptr] && swa_age > 16'd4095) a_v[csw_ptr] <= 1'b0;
                        csw_ptr <= (csw_ptr == NC - 1) ? 32'd0 : csw_ptr + 32'd1;
                        if (tr_on[k] && swt_age > {4'd0, T_DEAD_MS}) begin tr_on[k] <= 1'b0; tr_conf[k] <= 1'b0; end
                        k <= (k == TLAST) ? T0 : k + T1;
                    end
                end
                // ---- stage 3: ESTMD, one opposite-polarity neighbour per two cycles
                B_ESTMD_RD: begin
                    pw_t <= pol_t[nb_addr]; pw_v <= nb_in && pol_v[nb_addr];
                    st <= B_ESTMD_CHK;
                end
                B_ESTMD_CHK: begin
                    if (ebaf && !ehab && pw_v && pw_age >= TMIN_MS && pw_age <= TMAX_MS) corr <= 1'b1;
                    if ({24'd0, it} == NNB - 1) begin it <= 8'd0; st <= B_POLW; end else begin it <= it + 8'd1; st <= B_ESTMD_RD; end
                end
                B_POLW: begin
                    if (ebaf && !ehab) begin
                        if (USE_ESTMD != 0) begin
                            if (E_GATE != 0) resp <= corr; else begin resp <= 1'b1; if (corr) wgt <= 16'd16 + W_E_Q4; end
                        end else resp <= 1'b1;
                    end
                    if (ebaf) begin pol_t[(epol ? NPIX : 32'd0) + own_addr] <= enow; pol_v[(epol ? NPIX : 32'd0) + own_addr] <= 1'b1; end
                    st <= B_ARD;
                end
                // ---- stage 4: cells
                B_ARD: begin w_acc <= a_acc[ci]; w_t <= a_t[ci]; w_v <= a_v[ci]; b_w <= 16'd16; st <= B_AWR; end
                B_AWR: begin
                    if (ebaf) begin a_acc[ci] <= b_next; a_t[ci] <= b_t_next; a_v[ci] <= 1'b1; end
                    st <= B_RRD;
                end
                B_RRD: begin w_acc <= r_acc[ci]; w_t <= r_t[ci]; w_v <= r_v[ci]; b_w <= wgt; st <= B_RWR; end
                B_RWR: begin
                    if (resp) begin r_acc[ci] <= b_next; r_t[ci] <= b_t_next; r_v[ci] <= 1'b1; it <= 8'd0; st <= B_RING_RD; end
                    else st <= B_RETIRE;
                end
                B_RING_RD: begin
                    rr_acc <= r_acc[rg_addr]; rr_t <= r_t[rg_addr]; rr_v <= r_v[rg_addr];
                    ra_acc <= a_acc[rg_addr]; ra_t <= a_t[rg_addr]; ra_v <= a_v[rg_addr];
                    rg_in_r <= rg_in; rg_centre_r <= rg_centre;
                    st <= B_RING_ACC;
                end
                B_RING_ACC: begin
                    if (rg_in_r) begin
                        if (rg_centre_r) begin rc <= rc + {48'd0, acc_peek(rr_acc, enow, rr_t, rr_v)}; nc <= nc + 8'd1; end
                        else begin
                            rs <= rs + {48'd0, acc_peek(rr_acc, enow, rr_t, rr_v)}; ns <= ns + 8'd1;
                            as_ <= as_ + {48'd0, acc_peek(ra_acc, enow, ra_t, ra_v)};
                        end
                    end
                    if ({24'd0, it} == NRING - 1) begin it <= 8'd0; st <= B_SCORE; end else begin it <= it + 8'd1; st <= B_RING_RD; end
                end
                B_SCORE: begin
                    cand <= ((USE_SUR != 0 && ns != 8'd0) ? cand_sur : cand_ring) && !eglare;
                    st <= B_RETIRE;
                end
                // ---- stage 5: tracker
                B_RETIRE: begin
                    for (j = 0; j < NT; j = j + 1)
                        if (tr_on[j] && (enow - tr_tu[j]) > {4'd0, T_DEAD_MS}) begin tr_on[j] <= 1'b0; tr_conf[j] <= 1'b0; end
                    k <= T0; found <= 1'b0; bd <= 64'sh7FFFFFFFFFFFFFFF;
                    st <= (USE_TRK != 0 && cand) ? B_FIND : B_LABEL;
                end
                B_FIND: begin
                    if (hit_k) begin bd <= d2_k; best <= k; found <= 1'b1; end
                    if (k == TLAST) begin if (!hit_k) k <= best; st <= B_UPD; end else k <= k + T1;
                end
                B_UPD: begin          // k == best
                    if (found && bd <= $signed({16'd0, GATE2_Q16})) begin
                        tr_x[k] <= upd_x[31:0]; tr_y[k] <= upd_y[31:0];
                        tr_tu[k] <= enow; tr_hits[k] <= tr_hits[k] + 16'd1;
                        st <= B_DIVX;
                    end else begin
                        slot_free <= 1'b0; slot_age <= 16'd0; k <= T0; st <= B_SPAWN;
                    end
                end
                B_DIVX: begin         // velocity measurement when age(at) >= VDT, from the updated position
                    if (age_at_k >= {4'd0, VDT_MS}) begin
                        div_n <= abs64(sx32(dax)) << 8; div_neg <= dax[31]; div_d <= age_at_k;
                        div_cnt <= DIVN[5:0]; div_q <= 64'd0; div_rem <= 64'd0;
                        st <= B_DIVX_W;
                    end else st <= B_POST;
                end
                B_DIVX_W: begin       // restoring division, MSB first
                    if (div_cnt != 6'd0) begin
                        div_rem <= div_ge ? div_sh - {48'd0, div_d} : div_sh;
                        div_q <= {div_q[62:0], div_ge}; div_n <= div_n << 1; div_cnt <= div_cnt - 6'd1;
                    end else begin
                        vxm <= div_neg ? -$signed(div_q) : $signed(div_q);
                        div_n <= abs64(sx32(day)) << 8; div_neg <= day[31];
                        div_cnt <= DIVN[5:0]; div_q <= 64'd0; div_rem <= 64'd0;
                        st <= B_DIVY_W;
                    end
                end
                B_DIVY_W: begin
                    if (div_cnt != 6'd0) begin
                        div_rem <= div_ge ? div_sh - {48'd0, div_d} : div_sh;
                        div_q <= {div_q[62:0], div_ge}; div_n <= div_n << 1; div_cnt <= div_cnt - 6'd1;
                    end else begin
                        vym <= div_neg ? -$signed(div_q) : $signed(div_q);
                        st <= B_VEL;
                    end
                end
                B_VEL: begin
                    tr_vx[k] <= vx_upd[31:0]; tr_vy[k] <= vy_upd[31:0];
                    tr_ax[k] <= tr_x[k]; tr_ay[k] <= tr_y[k]; tr_at[k] <= enow;
                    st <= B_POST;
                end
                B_POST: begin
                    tr_dmax2[k] <= dmax2_new;
                    if (stat_due) begin tr_stat[k] <= stat_new; tr_cx[k] <= tr_x[k]; tr_cy[k] <= tr_y[k]; tr_ct[k] <= enow; end
                    tr_conf[k] <= conf_new;
                    if (conf_new && !stat_new) begin
                        trk_valid <= 1'b1; trk_uid <= tr_uid[k]; trk_x_q8 <= tr_x[k]; trk_y_q8 <= tr_y[k];
                    end
                    k <= T0; st <= B_LABEL;
                end
                B_SPAWN: begin        // first free slot, else the stalest unconfirmed track older than now
                    if (!slot_free) begin
                        if (!tr_on[k]) begin slot <= k; slot_free <= 1'b1; end
                        else if (!tr_conf[k] && age_tu_k > slot_age) begin slot <= k; slot_age <= age_tu_k; end
                    end
                    if (k == TLAST) st <= B_SPAWN_W; else k <= k + T1;
                end
                B_SPAWN_W: begin
                    if (slot_free || slot_age != 16'd0) begin
                        tr_on[slot] <= 1'b1; tr_conf[slot] <= 1'b0; tr_stat[slot] <= 1'b0;
                        tr_x[slot] <= xq; tr_y[slot] <= yq; tr_vx[slot] <= 32'sd0; tr_vy[slot] <= 32'sd0;
                        tr_tu[slot] <= enow; tr_at[slot] <= enow; tr_t0[slot] <= enow; tr_ct[slot] <= enow;
                        tr_ax[slot] <= xq; tr_ay[slot] <= yq; tr_x0[slot] <= xq; tr_y0[slot] <= yq; tr_cx[slot] <= xq; tr_cy[slot] <= yq;
                        tr_hits[slot] <= 16'd1; tr_dmax2[slot] <= 64'sd0; tr_uid[slot] <= uid_next; uid_next <= uid_next + 32'd1;
                    end
                    k <= T0; st <= B_LABEL;
                end
                // ---- stage 6: labelling
                B_LABEL: begin
                    if ((LAB_BAF == 0 || ebaf) && !eglare && USE_TRK != 0 && lab_hit) pred <= 1'b1;
                    if (k == TLAST) begin k <= T0; st <= B_OUT; end else k <= k + T1;
                end
                default: begin        // B_OUT
                    out_valid <= 1'b1; out_label <= (USE_TRK != 0) ? pred : cand; out_cand <= cand;
                    st <= B_IDLE;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
