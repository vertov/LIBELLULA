/*
 * stmd_ref.c — fixed-point, integer-only C99 reference of the LIBELLULA
 * small-target detector (stmd/libstmd/model.py), v26.
 *
 * This is the golden reference for RTL. Arithmetic is integer only:
 *   - time:        32-bit microsecond input, converted to 1 ms ticks; stored
 *                  per-pixel timestamps are 16-bit ms; ages saturate at 4095 ms
 *                  (12 bits), which is what the hardware budget assumes.
 *   - decays:      exp(-dt/tau) replaced by a 128-entry Q16 table indexed by
 *                  whole buckets of 2^shift ms (2^shift ~ tau/16) elapsed
 *                  since the accumulator's reference time; the reference time
 *                  advances by exactly the buckets applied, so the remainder
 *                  carries over (no under-decay at high event rates). Any
 *                  entry older than 4095 ms is expired (reads as zero /
 *                  invalid); the hardware sweep enforces this before 16-bit
 *                  timestamps can alias. No divisions: buckets and the rate
 *                  bucket are powers of two.
 *   - accumulators (flip count, cell response/activity, glare, global rate):
 *                  unsigned Q12.4 (16 bits) — one event adds 16.
 *   - weights (k_inh, k_act, w_estmd, theta, G_rate, F_max, alpha, vbeta):
 *                  Q4 or Q8 as noted at load time.
 *   - noise adaptation: the two per-event divisions in the Python model
 *                  (T_ba_eff and theta_eff from the rate) become 64-entry
 *                  tables indexed by the quantised global rate.
 *   - tracker:     positions Q8 px (int32), velocities Q16 px/ms (int32);
 *                  the velocity measurement uses one integer division by
 *                  dt_ms (>= vel_dt_ms); the squared-distance gate and the
 *                  displacement checks use integer squares.
 *
 * Differences from the Python model are quantisation only; the control flow
 * is the same, stage for stage. scripts/c_equivalence.py measures them.
 *
 * Build:  cc -O2 -std=c99 -o stmd_ref stmd_ref.c -lm
 * Run:    stmd_ref CONFIG.txt EVENTS.bin LABELS.bin TRACKS.txt [FRONTEND.bin]
 *   CONFIG.txt   key=value per line (written by cref.py from a JSON config)
 *   EVENTS.bin   records of int32 x, int32 y, int64 t_us, int8 p, 3 pad bytes
 *   LABELS.bin   one uint8 per event: 1 = target
 *   TRACKS.txt   t_us uid x_q8 y_q8 vx_q16 vy_q16 per confirmed-track update
 *   FRONTEND.bin optional, one uint8 per event with bit0 = baf, bit1 =
 *                habituated, bit2 = glare, bit3 = resp, bit4 = cand (for the
 *                RTL benches)
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define W 346
#define H 260
#define AGE_MAX 4095u          /* 12-bit saturating age in ms */
#define LUT_N 128
#define RATE_N 64
#define Q4 16
#define Q8 256
#define Q16 65536
#define MAX_TRACKS 32

typedef struct {
    uint32_t shift;            /* bucket = 2^shift ms, 2^shift ~ tau/16 */
    uint16_t lut[LUT_N];       /* Q16 exp(-k * 2^shift / tau_ms) */
} decay_t;

static void decay_init(decay_t *d, double tau_ms) {
    double k = log2(tau_ms / 16.0); d->shift = k < 0 ? 0 : (uint32_t)llround(k);
    double bucket = (double)(1u << d->shift);
    for (int k2 = 0; k2 < LUT_N; k2++) {
        double v = exp(-(double)k2 * bucket / tau_ms) * 65536.0;
        d->lut[k2] = (uint16_t)(v > 65535.0 ? 65535 : llround(v));
    }
}
/* All time differences are 16-bit (ms) with wrap. An entry whose age exceeds
 * AGE_MAX (4095 ms) is EXPIRED: it reads as invalid / zero. The hardware's
 * background sweep clears such entries before the 16-bit timestamp can
 * alias (it must visit every entry at least once per ~60 s), so this
 * read-time rule and the sweep agree exactly. */
/* C keeps full-width timestamps so that "age" is the true age; the RTL keeps
 * 16-bit ones plus a sweep, and the two agree as long as the sweep runs. */
static inline uint32_t age16(uint32_t now, uint32_t last) { return now - last; }
/* Lazy, telescoping decay: apply exp(-idx*bucket/tau) for the whole buckets
 * (power of two) elapsed since *t_ref, then advance *t_ref by exactly that
 * amount, so the remainder is carried to the next call. */
static inline uint32_t decay_step(const decay_t *d, uint32_t v, uint32_t now, uint32_t *t_ref) {
    uint32_t dt = age16(now, *t_ref);
    uint32_t idx = dt >> d->shift;
    if (dt > AGE_MAX || idx >= LUT_N) { *t_ref = now; return 0; }
    *t_ref = *t_ref + (idx << d->shift);
    return (uint32_t)(((uint64_t)v * d->lut[idx]) >> 16);
}
/* read-only peek (no state change) */
static inline uint32_t decay_peek(const decay_t *d, uint32_t v, uint32_t now, uint32_t t_ref) {
    uint32_t dt = age16(now, t_ref);
    uint32_t idx = dt >> d->shift;
    return (dt > AGE_MAX || idx >= LUT_N) ? 0 : (uint32_t)(((uint64_t)v * d->lut[idx]) >> 16);
}
static inline uint32_t age_ms(uint32_t now, uint32_t last, int valid) {
    if (!valid) return AGE_MAX;
    uint32_t a = age16(now, last);
    return a > AGE_MAX ? AGE_MAX : a;
}

/* ---- configuration ---------------------------------------------------- */
typedef struct {
    double v[64]; char k[64][32]; int n;
} kv_t;
static double cfg_get(const kv_t *c, const char *key, double dflt) {
    for (int i = 0; i < c->n; i++) if (!strcmp(c->k[i], key)) return c->v[i];
    return dflt;
}
static int kv_load(kv_t *c, const char *path) {
    FILE *f = fopen(path, "r"); if (!f) return -1;
    c->n = 0; char line[256];
    while (fgets(line, sizeof line, f) && c->n < 64) {
        char *eq = strchr(line, '='); if (!eq) continue; *eq = 0;
        size_t L = strlen(line); if (L > 31) L = 31; memcpy(c->k[c->n], line, L); c->k[c->n][L] = 0;
        c->v[c->n] = atof(eq + 1); c->n++;
    }
    fclose(f); return 0;
}

typedef struct {
    /* stage 1 */
    uint32_t T_ba;            /* ms */
    /* stage 2 */
    int use_hab; decay_t d_flip; uint32_t F_max_q4;
    /* stage 3 */
    int use_estmd, e_gate, nbr; uint32_t tmin, tmax; uint32_t w_e_q4;
    /* stage 4 */
    int cs, Hc, Wc, use_sur, sr; decay_t d_acc; uint32_t k_inh_q4, k_act_q4, theta_q4;
    /* stage 5 */
    int use_trk, NT; int32_t gate2_q16; uint32_t alpha_q8, vbeta_q8; uint32_t vdt_ms;
    uint32_t H_min, T_conf, T_dead, T_stat; int32_t D_min2_q16, D_stat2_q16;
    /* stage 6 */
    int32_t R_lab_q8; uint32_t T_lab; int lab_baf; uint32_t k_vlab_q8;
    /* stage 7 */
    int use_glare, gcs, Hg, Wg; decay_t d_g; uint32_t G_thr_q4;
    /* stage 8 */
    int use_noise; decay_t d_n; uint32_t rate_shift; uint32_t tba_lut[RATE_N], theta_lut[RATE_N]; uint8_t nsup_lut[RATE_N];
    uint32_t r_hi_idx; int n_sup_hi;
} params_t;

static void params_init(params_t *P, const kv_t *c) {
    P->T_ba = (uint32_t)llround(cfg_get(c, "T_ba_ms", 20));
    P->use_hab = cfg_get(c, "use_habituation", 1) > 0.5;
    decay_init(&P->d_flip, cfg_get(c, "tau_flip_ms", 1000));
    P->F_max_q4 = (uint32_t)llround(cfg_get(c, "F_max", 3) * Q4);
    P->use_estmd = cfg_get(c, "use_estmd", 1) > 0.5;
    P->e_gate = cfg_get(c, "estmd_gate", 1) > 0.5;
    P->nbr = (int)cfg_get(c, "nb_radius", 1);
    P->tmin = (uint32_t)llround(cfg_get(c, "tau_min_ms", 1));
    P->tmax = (uint32_t)llround(cfg_get(c, "tau_max_ms", 200));
    P->w_e_q4 = (uint32_t)llround(cfg_get(c, "w_estmd", 1) * Q4);
    P->cs = (int)cfg_get(c, "cell", 4); P->Hc = (H + P->cs - 1) / P->cs; P->Wc = (W + P->cs - 1) / P->cs;
    decay_init(&P->d_acc, cfg_get(c, "tau_acc_ms", 100));
    P->use_sur = cfg_get(c, "use_surround", 1) > 0.5; P->sr = (int)cfg_get(c, "surround_r", 3);
    P->k_inh_q4 = (uint32_t)llround(cfg_get(c, "k_inh", 1) * Q4);
    P->k_act_q4 = (uint32_t)llround(cfg_get(c, "k_act", 0) * Q4);
    P->theta_q4 = (uint32_t)llround(cfg_get(c, "theta", 3) * Q4);
    P->use_trk = cfg_get(c, "use_tracker", 1) > 0.5; P->NT = (int)cfg_get(c, "n_tracks", 8);
    if (P->NT > MAX_TRACKS) P->NT = MAX_TRACKS;
    { double g = cfg_get(c, "gate_px", 12); P->gate2_q16 = (int32_t)llround(g * g * Q16); }
    P->alpha_q8 = (uint32_t)llround(cfg_get(c, "alpha", 0.2) * Q8);
    P->vbeta_q8 = (uint32_t)llround(cfg_get(c, "vel_beta", 0.5) * Q8);
    P->vdt_ms = (uint32_t)llround(cfg_get(c, "vel_dt_ms", 50));
    P->H_min = (uint32_t)llround(cfg_get(c, "H_min", 8));
    P->T_conf = (uint32_t)llround(cfg_get(c, "T_conf_ms", 100));
    { double d = cfg_get(c, "D_min_px", 3); P->D_min2_q16 = (int32_t)llround(d * d * Q16); }
    P->T_dead = (uint32_t)llround(cfg_get(c, "T_dead_ms", 300));
    P->T_stat = (uint32_t)llround(cfg_get(c, "T_stat_ms", 500));
    { double d = cfg_get(c, "D_stat_px", 5); P->D_stat2_q16 = (int32_t)llround(d * d * Q16); }
    P->R_lab_q8 = (int32_t)llround(cfg_get(c, "R_lab_px", 6) * Q8);
    P->T_lab = (uint32_t)llround(cfg_get(c, "T_lab_ms", 100));
    P->lab_baf = cfg_get(c, "lab_requires_baf", 0) > 0.5;
    P->k_vlab_q8 = (uint32_t)llround(cfg_get(c, "k_vlab", 0) * Q8);
    P->use_glare = cfg_get(c, "use_glare", 0) > 0.5; P->gcs = (int)cfg_get(c, "g_cell", 8);
    P->Hg = (H + P->gcs - 1) / P->gcs; P->Wg = (W + P->gcs - 1) / P->gcs;
    { double tau_g = cfg_get(c, "tau_g_ms", 2000); decay_init(&P->d_g, tau_g);
      /* glare threshold: rate > G_rate  <=>  G_q4 > G_rate * (tau_g/1000) * gcs^2 * 16 */
      P->G_thr_q4 = (uint32_t)llround(cfg_get(c, "G_rate", 4) * (tau_g / 1000.0) * P->gcs * P->gcs * Q4); }
    P->use_noise = cfg_get(c, "use_noise_adapt", 0) > 0.5;
    { double tau_n = cfg_get(c, "tau_n_ms", 500); decay_init(&P->d_n, tau_n);
      double N_norm = (tau_n / 1000.0) * W * H;              /* events per unit rate */
      double rate_max = 4.0;                                   /* ev/px/s covered by the tables (nominal) */
      double stepq = rate_max / RATE_N * N_norm * Q4;          /* Q4 accumulator units per bucket */
      P->rate_shift = stepq < 1 ? 0 : (uint32_t)llround(log2(stepq));   /* power-of-two bucket */
      double r0 = cfg_get(c, "r0", 0.2), r_hi = cfg_get(c, "r_hi", 0.5), r_theta = cfg_get(c, "r_theta", 1.0);
      P->n_sup_hi = (int)cfg_get(c, "n_sup_hi", 2);
      for (int i = 0; i < RATE_N; i++) {
          double rate = (i + 0.5) * (double)(1u << P->rate_shift) / (N_norm * Q4);   /* bucket centre, ev/px/s */
          P->tba_lut[i] = (uint32_t)llround(P->T_ba / (1.0 + rate / r0));
          P->theta_lut[i] = (uint32_t)llround(cfg_get(c, "theta", 3) * (1.0 + rate / r_theta) * Q4);
          P->nsup_lut[i] = rate > r_hi ? (uint8_t)P->n_sup_hi : 1;
      }
    }
}

/* ---- state ------------------------------------------------------------ */
typedef struct {
    uint32_t last_any[H][W]; uint8_t any_valid[H][W];
    uint32_t last_pol[2][H][W]; uint8_t pol_valid[2][H][W];
    int8_t last_q[H][W];
    uint16_t flips[H][W]; uint32_t flip_t[H][W];
    uint16_t *R, *A; uint32_t *R_t, *A_t; /* Hc*Wc, Q12.4 and ms */
    uint8_t *R_valid, *A_valid;
    uint16_t *G; uint32_t *G_t; uint8_t *G_valid; /* Hg*Wg */
    uint32_t Ng; uint32_t Ng_t; uint8_t Ng_valid;
    /* tracks */
    int on[MAX_TRACKS], conf[MAX_TRACKS], stat[MAX_TRACKS];
    int32_t x[MAX_TRACKS], y[MAX_TRACKS];          /* Q8 */
    int32_t vx[MAX_TRACKS], vy[MAX_TRACKS];        /* Q16 px/ms */
    uint32_t tu[MAX_TRACKS], at[MAX_TRACKS], t0[MAX_TRACKS], ct[MAX_TRACKS];
    int32_t ax[MAX_TRACKS], ay[MAX_TRACKS], x0[MAX_TRACKS], y0[MAX_TRACKS], cx[MAX_TRACKS], cy[MAX_TRACKS];
    uint32_t hits[MAX_TRACKS]; int64_t dmax2[MAX_TRACKS]; int64_t uid[MAX_TRACKS]; int64_t uid_next;
} state_t;

static state_t *state_new(const params_t *P) {
    state_t *S = calloc(1, sizeof *S);
    int nc = P->Hc * P->Wc, ng = P->Hg * P->Wg;
    S->R = calloc(nc, 2); S->R_t = calloc(nc, 4); S->A = calloc(nc, 2); S->A_t = calloc(nc, 4);
    S->R_valid = calloc(nc, 1); S->A_valid = calloc(nc, 1);
    S->G = calloc(ng, 2); S->G_t = calloc(ng, 4); S->G_valid = calloc(ng, 1);
    memset(S->last_q, -1, sizeof S->last_q);
    return S;
}

/* Q12.4 accumulator update: decay (telescoping) then add w; saturate */
static inline uint16_t acc_bump(const decay_t *d, uint16_t v, uint32_t now, uint32_t *t_ref, uint8_t *valid, uint32_t w) {
    uint32_t nv;
    if (*valid) nv = decay_step(d, v, now, t_ref); else { nv = 0; *t_ref = now; *valid = 1; }
    nv += w; return nv > 65535 ? 65535 : (uint16_t)nv;
}
static inline uint32_t acc_read(const decay_t *d, uint16_t v, uint32_t now, uint32_t t_ref, uint8_t valid) {
    return valid ? decay_peek(d, v, now, t_ref) : 0;
}

/* ---- front-end stages (mirrored by the RTL) ---------------------------- */
/* Stage 8 (global rate) + table lookups. Returns rate bucket index. */
static inline int fe_noise(const params_t *P, state_t *S, uint32_t now, uint32_t *T_ba_eff, int *n_sup, uint32_t *theta_eff) {
    *T_ba_eff = P->T_ba; *n_sup = 1; *theta_eff = P->theta_q4;
    if (!P->use_noise) return -1;
    uint32_t v;
    if (S->Ng_valid) v = decay_step(&P->d_n, S->Ng, now, &S->Ng_t); else { v = 0; S->Ng_t = now; S->Ng_valid = 1; }
    v += Q4; if (v > 0xFFFFFF) v = 0xFFFFFF;           /* 24-bit global accumulator */
    S->Ng = v;
    uint32_t idx = v >> P->rate_shift; if (idx >= RATE_N) idx = RATE_N - 1;
    *T_ba_eff = P->tba_lut[idx]; *n_sup = P->nsup_lut[idx]; *theta_eff = P->theta_lut[idx];
    return (int)idx;
}
/* Stage 7 (glare): update region accumulator, return muted flag */
static inline int fe_glare(const params_t *P, state_t *S, int x, int y, uint32_t now) {
    if (!P->use_glare) return 0;
    int gi = (y / P->gcs) * P->Wg + (x / P->gcs);
    S->G[gi] = acc_bump(&P->d_g, S->G[gi], now, &S->G_t[gi], &S->G_valid[gi], Q4);
    return S->G[gi] > P->G_thr_q4;
}
/* Stage 1 (activity filter): count neighbours within T_ba_eff, then write own timestamp */
static inline int fe_baf(const params_t *P, state_t *S, int x, int y, uint32_t now, uint32_t T_ba_eff, int n_sup) {
    (void)P; int sup = 0;
    for (int dy = -1; dy <= 1; dy++) { int yy = y + dy; if (yy < 0 || yy >= H) continue;
        for (int dx = -1; dx <= 1; dx++) { if (!dx && !dy) continue; int xx = x + dx; if (xx < 0 || xx >= W) continue;
            if (age_ms(now, S->last_any[yy][xx], S->any_valid[yy][xx]) <= T_ba_eff) sup++; } }
    S->last_any[y][x] = now; S->any_valid[y][x] = 1;
    return sup >= n_sup;
}
/* Stage 2 (habituation): leaky polarity-reversal count */
static inline int fe_habit(const params_t *P, state_t *S, int x, int y, uint32_t now, int q) {
    uint32_t f;
    if (S->last_q[y][x] >= 0) f = decay_step(&P->d_flip, S->flips[y][x], now, &S->flip_t[y][x]);
    else { f = 0; S->flip_t[y][x] = now; }
    if (S->last_q[y][x] >= 0 && S->last_q[y][x] != q) f += Q4;
    if (f > 65535) f = 65535;
    S->flips[y][x] = (uint16_t)f; S->last_q[y][x] = (int8_t)q;
    return P->use_hab && f > P->F_max_q4;
}

/* ---- main per-event function ------------------------------------------ */
typedef struct { int32_t x, y; int64_t t_us; int8_t p; int8_t pad[3]; } event_t;

static int process(const params_t *P, state_t *S, const event_t *e, uint8_t *fe_bits, FILE *ftrk) {
    int xi = e->x, yi = e->y, q = e->p ? 1 : 0;
    uint32_t now = (uint32_t)(e->t_us / 1000);           /* ms tick */

    uint32_t T_ba_eff, theta_eff; int n_sup;
    fe_noise(P, S, now, &T_ba_eff, &n_sup, &theta_eff);
    int glare = fe_glare(P, S, xi, yi, now);
    int baf = fe_baf(P, S, xi, yi, now, T_ba_eff, n_sup);
    int habituated = fe_habit(P, S, xi, yi, now, q);

    /* stage 3: ESTMD */
    int resp = 0; uint32_t wgt = Q4;
    if (baf && !habituated) {
        if (P->use_estmd) {
            int corr = 0;
            for (int dy = -P->nbr; dy <= P->nbr; dy++) { int yy = yi + dy; if (yy < 0 || yy >= H) continue;
                for (int dx = -P->nbr; dx <= P->nbr; dx++) { int xx = xi + dx; if (xx < 0 || xx >= W) continue;
                    if (!S->pol_valid[1 - q][yy][xx]) continue;
                    uint32_t d = age_ms(now, S->last_pol[1 - q][yy][xx], 1);
                    if (d >= P->tmin && d <= P->tmax) corr = 1; } }
            if (P->e_gate) resp = corr; else { resp = 1; if (corr) wgt = Q4 + P->w_e_q4; }
        } else resp = 1;
    }
    if (baf) { S->last_pol[q][yi][xi] = now; S->pol_valid[q][yi][xi] = 1; }

    /* stage 4: cells + centre-surround */
    int cand = 0;
    int cy = yi / P->cs, cx = xi / P->cs, ci = cy * P->Wc + cx;
    if (baf) S->A[ci] = acc_bump(&P->d_acc, S->A[ci], now, &S->A_t[ci], &S->A_valid[ci], Q4);
    if (resp) {
        S->R[ci] = acc_bump(&P->d_acc, S->R[ci], now, &S->R_t[ci], &S->R_valid[ci], wgt);
        uint64_t rc = 0, rs = 0, as = 0; int nc = 0, ns = 0;
        int rr = P->use_sur ? P->sr : 1;
        for (int dy = -rr; dy <= rr; dy++) { int yy = cy + dy; if (yy < 0 || yy >= P->Hc) continue;
            for (int dx = -rr; dx <= rr; dx++) { int xx = cx + dx; if (xx < 0 || xx >= P->Wc) continue;
                int j = yy * P->Wc + xx;
                uint32_t v = acc_read(&P->d_acc, S->R[j], now, S->R_t[j], S->R_valid[j]);
                if (abs(dy) <= 1 && abs(dx) <= 1) { rc += v; nc++; }
                else { rs += v; ns++; as += acc_read(&P->d_acc, S->A[j], now, S->A_t[j], S->A_valid[j]); } } }
        /* score >= theta  <=>  rc*ns*16 - (k_inh*rs + k_act*as)*nc >= theta*ns*16   (all Q4 weights) */
        if (P->use_sur && ns > 0) {
            int64_t lhs = (int64_t)rc * ns * Q4 - (int64_t)(P->k_inh_q4 * rs + P->k_act_q4 * as) * nc;
            cand = lhs >= (int64_t)theta_eff * ns * Q4;
        } else cand = rc >= theta_eff;                                   /* both Q4 */
        if (glare) cand = 0;
    }
    if (fe_bits) *fe_bits = (uint8_t)(baf | habituated << 1 | glare << 2 | resp << 3 | cand << 4);

    /* stage 5: tracker */
    int pred = 0;
    if (!P->use_trk) return cand;
    for (int k = 0; k < P->NT; k++) if (S->on[k] && age16(now, S->tu[k]) > P->T_dead) { S->on[k] = 0; S->conf[k] = 0; }
    if (cand) {
        int best = -1; int64_t bd = INT64_MAX; int32_t xq = xi * Q8, yq = yi * Q8;
        for (int k = 0; k < P->NT; k++) { if (!S->on[k]) continue;
            int32_t dt = (int32_t)age16(now, S->tu[k]);
            int64_t px = S->x[k] + (((int64_t)S->vx[k] * dt) >> 8), py = S->y[k] + (((int64_t)S->vy[k] * dt) >> 8);
            int64_t d2 = (xq - px) * (xq - px) + (yq - py) * (yq - py);   /* Q16 px^2 */
            if (d2 < bd) { bd = d2; best = k; } }
        if (best >= 0 && bd <= P->gate2_q16) {
            int k = best; int32_t dt = (int32_t)age16(now, S->tu[k]);
            int64_t px = S->x[k] + (((int64_t)S->vx[k] * dt) >> 8), py = S->y[k] + (((int64_t)S->vy[k] * dt) >> 8);
            S->x[k] = (int32_t)(px + (((int64_t)P->alpha_q8 * (xq - px)) >> 8));
            S->y[k] = (int32_t)(py + (((int64_t)P->alpha_q8 * (yq - py)) >> 8));
            S->tu[k] = now; S->hits[k]++;
            if (age16(now, S->at[k]) >= P->vdt_ms) {
                int32_t dta = (int32_t)age16(now, S->at[k]);
                int32_t vxm = (int32_t)(((int64_t)(S->x[k] - S->ax[k]) * Q8) / dta);   /* Q8 px * 2^8 / ms = Q16 px/ms */
                int32_t vym = (int32_t)(((int64_t)(S->y[k] - S->ay[k]) * Q8) / dta);
                S->vx[k] += (int32_t)(((int64_t)P->vbeta_q8 * (vxm - S->vx[k])) >> 8);
                S->vy[k] += (int32_t)(((int64_t)P->vbeta_q8 * (vym - S->vy[k])) >> 8);
                S->ax[k] = S->x[k]; S->ay[k] = S->y[k]; S->at[k] = now; }
            int64_t dd2 = (int64_t)(S->x[k] - S->x0[k]) * (S->x[k] - S->x0[k]) + (int64_t)(S->y[k] - S->y0[k]) * (S->y[k] - S->y0[k]);
            if (dd2 > S->dmax2[k]) S->dmax2[k] = dd2;
            if (P->T_stat > 0 && age16(now, S->ct[k]) >= P->T_stat) {
                int64_t ds2 = (int64_t)(S->x[k] - S->cx[k]) * (S->x[k] - S->cx[k]) + (int64_t)(S->y[k] - S->cy[k]) * (S->y[k] - S->cy[k]);
                S->stat[k] = ds2 < P->D_stat2_q16; S->cx[k] = S->x[k]; S->cy[k] = S->y[k]; S->ct[k] = now; }
            if (!S->conf[k] && S->hits[k] >= P->H_min && age16(now, S->t0[k]) >= P->T_conf && S->dmax2[k] >= P->D_min2_q16) S->conf[k] = 1;
            if (S->conf[k] && !S->stat[k] && ftrk)
                fprintf(ftrk, "%lld %lld %d %d %d %d\n", (long long)e->t_us, (long long)S->uid[k], S->x[k], S->y[k], S->vx[k], S->vy[k]);
        } else {
            int slot = -1;
            for (int k = 0; k < P->NT; k++) if (!S->on[k]) { slot = k; break; }
            if (slot < 0) { uint32_t old = now; for (int k = 0; k < P->NT; k++) if (!S->conf[k] && S->tu[k] < old) { old = S->tu[k]; slot = k; } }
            if (slot >= 0) { int k = slot; S->on[k] = 1; S->conf[k] = 0; S->stat[k] = 0;
                S->x[k] = xq; S->y[k] = yq; S->vx[k] = S->vy[k] = 0; S->tu[k] = S->at[k] = S->t0[k] = S->ct[k] = now;
                S->ax[k] = S->x0[k] = S->cx[k] = xq; S->ay[k] = S->y0[k] = S->cy[k] = yq; S->hits[k] = 1; S->dmax2[k] = 0;
                S->uid[k] = S->uid_next++; }
        }
    }
    /* stage 6: labelling */
    if ((!P->lab_baf || baf) && !glare) {
        int32_t xq = xi * Q8, yq = yi * Q8;
        for (int k = 0; k < P->NT; k++) { if (!(S->on[k] && S->conf[k] && !S->stat[k] && age16(now, S->tu[k]) <= P->T_lab)) continue;
            int32_t dt = (int32_t)age16(now, S->tu[k]);
            int64_t px = S->x[k] + (((int64_t)S->vx[k] * dt) >> 8), py = S->y[k] + (((int64_t)S->vy[k] * dt) >> 8);
            int64_t ex = P->R_lab_q8 + ((((int64_t)P->k_vlab_q8 * llabs(S->vx[k])) >> 8) * P->T_lab >> 8);
            int64_t ey = P->R_lab_q8 + ((((int64_t)P->k_vlab_q8 * llabs(S->vy[k])) >> 8) * P->T_lab >> 8);
            if (llabs(xq - px) <= ex && llabs(yq - py) <= ey) { pred = 1; break; } }
    }
    return pred;
}

/* --dump-tables CONFIG.txt OUT_DIR: write the front-end constants and
 * lookup tables as $readmemh files + a Verilog parameter include, so the RTL
 * uses exactly the C tables. */
static int dump_tables(const params_t *P, const char *dir) {
    char path[512]; FILE *f;
#define OPEN(name) (snprintf(path, sizeof path, "%s/%s", dir, name), f = fopen(path, "w"), f ? 0 : (perror(path), 1))
#define DUMP(name, N, fmt, expr) do { if (OPEN(name)) return 1; \
        for (int k = 0; k < (N); k++) { fprintf(f, fmt "\n", (expr)); } \
        fclose(f); } while (0)
    DUMP("lut_flip.hex", LUT_N, "%04x", P->d_flip.lut[k]);
    DUMP("lut_g.hex", LUT_N, "%04x", P->d_g.lut[k]);
    DUMP("lut_n.hex", LUT_N, "%04x", P->d_n.lut[k]);
    DUMP("tba_lut.hex", RATE_N, "%04x", P->tba_lut[k]);
    DUMP("nsup_lut.hex", RATE_N, "%02x", P->nsup_lut[k]);
    DUMP("theta_lut.hex", RATE_N, "%04x", P->theta_lut[k]);
    if (OPEN("fe_params.vh")) return 1;
    fprintf(f, "// generated by stmd_ref --dump-tables\n");
    fprintf(f, "localparam [15:0] T_BA_MS     = 16'd%u;\n", P->T_ba);
    fprintf(f, "localparam        USE_HAB     = %d;\n", P->use_hab);
    fprintf(f, "localparam [15:0] F_MAX_Q4    = 16'd%u;\n", P->F_max_q4);
    fprintf(f, "localparam [3:0]  SHIFT_FLIP  = 4'd%u;\n", P->d_flip.shift);
    fprintf(f, "localparam        USE_GLARE   = %d;\n", P->use_glare);
    fprintf(f, "localparam        G_CELL      = %d;\n", P->gcs);
    fprintf(f, "localparam [15:0] G_THR_Q4    = 16'd%u;\n", P->G_thr_q4 > 65535 ? 65535 : P->G_thr_q4);
    fprintf(f, "localparam [3:0]  SHIFT_G     = 4'd%u;\n", P->d_g.shift);
    fprintf(f, "localparam        USE_NOISE   = %d;\n", P->use_noise);
    fprintf(f, "localparam [3:0]  SHIFT_N     = 4'd%u;\n", P->d_n.shift);
    fprintf(f, "localparam [4:0]  RATE_SHIFT  = 5'd%u;\n", P->rate_shift);
    fprintf(f, "// back end\n");
    fprintf(f, "localparam        USE_ESTMD   = %d;\n", P->use_estmd);
    fprintf(f, "localparam        E_GATE      = %d;\n", P->e_gate);
    fprintf(f, "localparam        NBR         = %d;\n", P->nbr);
    fprintf(f, "localparam [11:0] TMIN_MS     = 12'd%u;\n", P->tmin);
    fprintf(f, "localparam [11:0] TMAX_MS     = 12'd%u;\n", P->tmax);
    fprintf(f, "localparam [15:0] W_E_Q4      = 16'd%u;\n", P->w_e_q4);
    fprintf(f, "localparam        CELL        = %d;\n", P->cs);
    fprintf(f, "localparam        HC          = %d;\n", P->Hc);
    fprintf(f, "localparam        WC          = %d;\n", P->Wc);
    fprintf(f, "localparam [3:0]  SHIFT_ACC   = 4'd%u;\n", P->d_acc.shift);
    fprintf(f, "localparam        USE_SUR     = %d;\n", P->use_sur);
    fprintf(f, "localparam        SR          = %d;\n", P->sr);
    fprintf(f, "localparam [15:0] K_INH_Q4    = 16'd%u;\n", P->k_inh_q4);
    fprintf(f, "localparam [15:0] K_ACT_Q4    = 16'd%u;\n", P->k_act_q4);
    fprintf(f, "localparam        USE_TRK     = %d;\n", P->use_trk);
    fprintf(f, "localparam        NT          = %d;\n", P->NT);
    fprintf(f, "localparam [47:0] GATE2_Q16   = 48'd%lld;\n", (long long)P->gate2_q16);
    fprintf(f, "localparam [15:0] ALPHA_Q8    = 16'd%u;\n", P->alpha_q8);
    fprintf(f, "localparam [15:0] VBETA_Q8    = 16'd%u;\n", P->vbeta_q8);
    fprintf(f, "localparam [11:0] VDT_MS      = 12'd%u;\n", P->vdt_ms);
    fprintf(f, "localparam [15:0] H_MIN       = 16'd%u;\n", P->H_min);
    fprintf(f, "localparam [11:0] T_CONF_MS   = 12'd%u;\n", P->T_conf);
    fprintf(f, "localparam [47:0] D_MIN2_Q16  = 48'd%lld;\n", (long long)P->D_min2_q16);
    fprintf(f, "localparam [11:0] T_DEAD_MS   = 12'd%u;\n", P->T_dead);
    fprintf(f, "localparam [11:0] T_STAT_MS   = 12'd%u;\n", P->T_stat);
    fprintf(f, "localparam [47:0] D_STAT2_Q16 = 48'd%lld;\n", (long long)P->D_stat2_q16);
    fprintf(f, "localparam [23:0] R_LAB_Q8    = 24'd%lld;\n", (long long)P->R_lab_q8);
    fprintf(f, "localparam [11:0] T_LAB_MS    = 12'd%u;\n", P->T_lab);
    fprintf(f, "localparam        LAB_BAF     = %d;\n", P->lab_baf);
    fprintf(f, "localparam [15:0] K_VLAB_Q8   = 16'd%u;\n", P->k_vlab_q8);
    fclose(f);
    DUMP("lut_acc.hex", LUT_N, "%04x", P->d_acc.lut[k]);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 4 && !strcmp(argv[1], "--dump-tables")) {
        kv_t kv; if (kv_load(&kv, argv[2])) { perror(argv[2]); return 1; }
        params_t P; params_init(&P, &kv); return dump_tables(&P, argv[3]);
    }
    if (argc < 5) { fprintf(stderr, "usage: %s CONFIG.txt EVENTS.bin LABELS.bin TRACKS.txt [FRONTEND.bin]\n       %s --dump-tables CONFIG.txt OUT_DIR\n", argv[0], argv[0]); return 2; }
    kv_t kv; if (kv_load(&kv, argv[1])) { perror(argv[1]); return 1; }
    params_t P; params_init(&P, &kv);
    state_t *S = state_new(&P);
    FILE *fe = fopen(argv[2], "rb"), *fl = fopen(argv[3], "wb"), *ft = fopen(argv[4], "w");
    FILE *ff = argc > 5 ? fopen(argv[5], "wb") : NULL;
    if (!fe || !fl || !ft) { perror("open"); return 1; }
    event_t ev; uint8_t bits;
    while (fread(&ev, sizeof ev, 1, fe) == 1) {
        if (ev.x < 0 || ev.x >= W || ev.y < 0 || ev.y >= H) { fputc(0, fl); if (ff) fputc(0, ff); continue; }
        uint8_t lab = (uint8_t)process(&P, S, &ev, ff ? &bits : NULL, ft);
        fputc(lab, fl); if (ff) fputc(bits, ff);
    }
    fclose(fe); fclose(fl); fclose(ft); if (ff) fclose(ff);
    return 0;
}
