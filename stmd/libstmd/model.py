"""Event-driven small-target motion detector (reference model).

Conceptual successor to the LIBELLULA core: the same per-event, fixed-point-
friendly style, re-aimed at detecting tiny moving targets. Each stage maps to
a known insect mechanism or to an existing LIBELLULA block:

  1. Background-activity filter (BAF): an event passes only if one of its 8
     neighbours fired within T_ba. (LIBELLULA activity_filter.v.)
  2. Flicker habituation: a per-pixel leaky count of polarity reversals. A
     target crossing a pixel reverses it about once (dark edge then light
     edge); a flickering light reverses it continually. Pixels above F_max
     are suppressed.
  3. ESTMD correlation (Wiederman et al. 2008): an event of polarity q is a
     "small-target response" if the opposite polarity fired in its
     neighbourhood between tau_min and tau_max earlier. A small object makes
     an OFF edge followed shortly by an ON edge (or the reverse); a single
     edge or a large object does not. Evaluated per event from two
     timestamp maps, no frames.
  4. Centre-surround inhibition on a coarse cell grid: response accumulated
     in the 3x3-cell centre minus the area-normalised surround, where the
     surround term is k_inh x responses plus k_act x all filtered activity in
     the ring. Small isolated responders survive; extended responding or
     merely busy regions (foliage, glare) are suppressed.
  5. Tracker pool (LIBELLULA tracker_pool + alpha-beta): candidate responses
     feed gated tracks. A track is confirmed only after H_min hits spanning
     T_conf and net displacement >= D_min. Every T_stat a track's displacement
     is checked; a track that moved < D_stat is marked static and stops
     labelling (it still absorbs candidates, so a flickering light or the sun
     does not keep spawning new tracks). Biologically, this plays the role of
     STMD facilitation: response is built along a moving trajectory.
  6. Event labelling: an event is labelled target if it lies within R_lab
     (Chebyshev) of a confirmed track's predicted position.

All state is per-pixel timestamps / small counters plus per-cell leaky
accumulators and a fixed number of track slots. Everything is causal: an
event's label uses only earlier events.
"""
from __future__ import annotations

from dataclasses import dataclass, asdict, fields

import numpy as np
from numba import njit

W, H = 346, 260


@dataclass
class Params:
    # 1. background-activity filter
    T_ba_ms: float = 20.0
    # 2. flicker habituation
    use_habituation: bool = True
    tau_flip_ms: float = 1000.0
    F_max: float = 3.0
    # 3. ESTMD polarity correlation
    use_estmd: bool = True
    tau_min_ms: float = 1.0
    tau_max_ms: float = 200.0
    nb_radius: int = 1          # 0 = same pixel, 1 = 3x3
    estmd_gate: bool = True     # True: only correlated events respond.
                                # False: every filtered event responds with
                                # weight 1, correlated events add w_estmd.
    w_estmd: float = 1.0
    # 4. cells and centre-surround
    cell: int = 4
    tau_acc_ms: float = 100.0
    use_surround: bool = True
    surround_r: int = 3         # ring = (2r+1)^2 cells minus 3x3 centre
    k_inh: float = 1.0
    k_act: float = 0.0          # surround inhibition from all filtered activity (input-side surround)
    theta: float = 3.0
    # 5. tracker
    use_tracker: bool = True
    n_tracks: int = 8
    gate_px: float = 12.0
    alpha: float = 0.2
    vel_dt_ms: float = 50.0
    vel_beta: float = 0.5
    H_min: int = 8
    T_conf_ms: float = 100.0
    D_min_px: float = 3.0
    T_dead_ms: float = 300.0
    T_stat_ms: float = 500.0     # stationarity check interval (0 = off)
    D_stat_px: float = 5.0       # min displacement per interval to stay "moving"
    # 6. labelling
    R_lab_px: float = 6.0
    T_lab_ms: float = 100.0
    lab_requires_baf: bool = False
    k_vlab: float = 0.0          # extend label box along velocity: +k_vlab*|v|*T_lab

    def as_tuple(self):
        return tuple(float(getattr(self, f.name)) for f in fields(self))

    def to_dict(self):
        return asdict(self)


# Order in which _run() reads the parameter vector. Adding a Params field
# requires adding it here and to the unpacking block in _run().
KEYS = (
    "T_ba_ms",
    "use_habituation",
    "tau_flip_ms",
    "F_max",
    "use_estmd",
    "tau_min_ms",
    "tau_max_ms",
    "nb_radius",
    "estmd_gate",
    "w_estmd",
    "cell",
    "tau_acc_ms",
    "use_surround",
    "surround_r",
    "k_inh",
    "k_act",
    "theta",
    "use_tracker",
    "n_tracks",
    "gate_px",
    "alpha",
    "vel_dt_ms",
    "vel_beta",
    "H_min",
    "T_conf_ms",
    "D_min_px",
    "T_dead_ms",
    "T_stat_ms",
    "D_stat_px",
    "R_lab_px",
    "T_lab_ms",
    "lab_requires_baf",
    "k_vlab",
)
assert set(KEYS) == {f.name for f in fields(Params)}, "KEYS out of sync with Params"



@njit(cache=True)
def _run(x, y, t, p, P):
    n = x.shape[0]
    T_ba = P[0] * 1000.0   # T_ba_ms
    use_hab = P[1] > 0.5   # use_habituation
    tau_flip = P[2] * 1000.0   # tau_flip_ms
    F_max = P[3]   # F_max
    use_estmd = P[4] > 0.5   # use_estmd
    tmin = P[5] * 1000.0   # tau_min_ms
    tmax = P[6] * 1000.0   # tau_max_ms
    nbr = int(P[7])   # nb_radius
    e_gate = P[8] > 0.5   # estmd_gate
    w_e = P[9]   # w_estmd
    cs = int(P[10])   # cell
    tau_acc = P[11] * 1000.0   # tau_acc_ms
    use_sur = P[12] > 0.5   # use_surround
    sr = int(P[13])   # surround_r
    k_inh = P[14]   # k_inh
    k_act = P[15]   # k_act
    theta = P[16]   # theta
    use_trk = P[17] > 0.5   # use_tracker
    NT = int(P[18])   # n_tracks
    gate = P[19]   # gate_px
    alpha = P[20]   # alpha
    vdt = P[21] * 1000.0   # vel_dt_ms
    vbeta = P[22]   # vel_beta
    H_min = P[23]   # H_min
    T_conf = P[24] * 1000.0   # T_conf_ms
    D_min = P[25]   # D_min_px
    T_dead = P[26] * 1000.0   # T_dead_ms
    T_stat = P[27] * 1000.0   # T_stat_ms
    D_stat = P[28]   # D_stat_px
    R_lab = P[29]   # R_lab_px
    T_lab = P[30] * 1000.0   # T_lab_ms
    lab_baf = P[31] > 0.5   # lab_requires_baf
    k_vlab = P[32]   # k_vlab

    NEG = -(1 << 60)
    last_any = np.full((H, W), NEG, np.int64)
    last_pol = np.full((2, H, W), NEG, np.int64)
    last_q = np.full((H, W), -1, np.int8)
    flips = np.zeros((H, W), np.float64)
    flip_t = np.zeros((H, W), np.int64)

    Hc = (H + cs - 1) // cs
    Wc = (W + cs - 1) // cs
    R = np.zeros((Hc, Wc), np.float64)
    R_t = np.zeros((Hc, Wc), np.int64)
    A = np.zeros((Hc, Wc), np.float64)
    A_t = np.zeros((Hc, Wc), np.int64)

    # tracks
    tr_on = np.zeros(NT, np.bool_)
    tr_x = np.zeros(NT); tr_y = np.zeros(NT)
    tr_vx = np.zeros(NT); tr_vy = np.zeros(NT)
    tr_tu = np.zeros(NT, np.int64)          # time of last position update
    tr_ax = np.zeros(NT); tr_ay = np.zeros(NT)
    tr_at = np.zeros(NT, np.int64)          # velocity anchor
    tr_hits = np.zeros(NT)
    tr_t0 = np.zeros(NT, np.int64)
    tr_x0 = np.zeros(NT); tr_y0 = np.zeros(NT)
    tr_conf = np.zeros(NT, np.bool_)
    tr_dmax = np.zeros(NT)
    tr_cx = np.zeros(NT); tr_cy = np.zeros(NT)
    tr_ct = np.zeros(NT, np.int64)          # stationarity checkpoint
    tr_static = np.zeros(NT, np.bool_)

    pred = np.zeros(n, np.uint8)
    baf_out = np.zeros(n, np.uint8)
    resp_out = np.zeros(n, np.uint8)
    cand_out = np.zeros(n, np.uint8)
    assign = np.full(n, -1, np.int16)      # track slot that absorbed this candidate (+100 if spawned)
    n_confirm = 0

    for i in range(n):
        xi = x[i]; yi = y[i]; ti = t[i]; q = p[i]

        # ---- 1. background-activity filter (8 neighbours, not self)
        baf = False
        for dy in range(-1, 2):
            yy = yi + dy
            if yy < 0 or yy >= H:
                continue
            for dx in range(-1, 2):
                if dx == 0 and dy == 0:
                    continue
                xx = xi + dx
                if xx < 0 or xx >= W:
                    continue
                if ti - last_any[yy, xx] <= T_ba:
                    baf = True
        last_any[yi, xi] = ti
        baf_out[i] = baf

        # ---- 2. flicker habituation (per-pixel reversal count, leaky)
        f = flips[yi, xi] * np.exp(-(ti - flip_t[yi, xi]) / tau_flip)
        if last_q[yi, xi] >= 0 and last_q[yi, xi] != q:
            f += 1.0
        flips[yi, xi] = f
        flip_t[yi, xi] = ti
        last_q[yi, xi] = q
        habituated = use_hab and f > F_max

        # ---- 3. ESTMD response
        resp = False
        wgt = 1.0
        if baf and not habituated:
            if use_estmd:
                corr = False
                for dy in range(-nbr, nbr + 1):
                    yy = yi + dy
                    if yy < 0 or yy >= H:
                        continue
                    for dx in range(-nbr, nbr + 1):
                        xx = xi + dx
                        if xx < 0 or xx >= W:
                            continue
                        d = ti - last_pol[1 - q, yy, xx]
                        if d >= tmin and d <= tmax:
                            corr = True
                if e_gate:
                    resp = corr
                else:
                    resp = True
                    if corr:
                        wgt = 1.0 + w_e
            else:
                resp = True
        if baf:
            last_pol[q, yi, xi] = ti   # polarity memory holds filtered events only
        resp_out[i] = resp

        # ---- 4. cell accumulation + centre-surround
        cand = False
        if baf:
            cy = yi // cs; cx = xi // cs
            A[cy, cx] = A[cy, cx] * np.exp(-(ti - A_t[cy, cx]) / tau_acc) + 1.0
            A_t[cy, cx] = ti
        if resp:
            cy = yi // cs; cx = xi // cs
            R[cy, cx] = R[cy, cx] * np.exp(-(ti - R_t[cy, cx]) / tau_acc) + wgt
            R_t[cy, cx] = ti
            rc = 0.0; rs = 0.0; as_ = 0.0; nc = 0; ns = 0
            rr = sr if use_sur else 1
            for dy in range(-rr, rr + 1):
                yy = cy + dy
                if yy < 0 or yy >= Hc:
                    continue
                for dx in range(-rr, rr + 1):
                    xx = cx + dx
                    if xx < 0 or xx >= Wc:
                        continue
                    v = R[yy, xx] * np.exp(-(ti - R_t[yy, xx]) / tau_acc)
                    if abs(dy) <= 1 and abs(dx) <= 1:
                        rc += v; nc += 1
                    else:
                        rs += v; ns += 1
                        as_ += A[yy, xx] * np.exp(-(ti - A_t[yy, xx]) / tau_acc)
            score = rc
            if use_sur and ns > 0:
                score = rc - (k_inh * rs + k_act * as_) * nc / ns
            cand = score >= theta
        cand_out[i] = cand

        # ---- 5. tracker
        if use_trk:
            # retire stale tracks
            for k in range(NT):
                if tr_on[k] and ti - tr_tu[k] > T_dead:
                    tr_on[k] = False
                    tr_conf[k] = False
            if cand:
                best = -1; bd = 1e18
                for k in range(NT):
                    if not tr_on[k]:
                        continue
                    dtk = ti - tr_tu[k]
                    px_ = tr_x[k] + tr_vx[k] * dtk
                    py_ = tr_y[k] + tr_vy[k] * dtk
                    d2 = (xi - px_) ** 2 + (yi - py_) ** 2
                    if d2 < bd:
                        bd = d2; best = k
                if best >= 0 and bd <= gate * gate:
                    k = best
                    dtk = ti - tr_tu[k]
                    px_ = tr_x[k] + tr_vx[k] * dtk
                    py_ = tr_y[k] + tr_vy[k] * dtk
                    tr_x[k] = px_ + alpha * (xi - px_)
                    tr_y[k] = py_ + alpha * (yi - py_)
                    tr_tu[k] = ti
                    tr_hits[k] += 1
                    assign[i] = k
                    if ti - tr_at[k] >= vdt:
                        dta = ti - tr_at[k]
                        vx_m = (tr_x[k] - tr_ax[k]) / dta
                        vy_m = (tr_y[k] - tr_ay[k]) / dta
                        tr_vx[k] = tr_vx[k] + vbeta * (vx_m - tr_vx[k])
                        tr_vy[k] = tr_vy[k] + vbeta * (vy_m - tr_vy[k])
                        tr_ax[k] = tr_x[k]; tr_ay[k] = tr_y[k]; tr_at[k] = ti
                    dd = np.sqrt((tr_x[k] - tr_x0[k]) ** 2 + (tr_y[k] - tr_y0[k]) ** 2)
                    if dd > tr_dmax[k]:
                        tr_dmax[k] = dd
                    if T_stat > 0 and ti - tr_ct[k] >= T_stat:
                        ds = np.sqrt((tr_x[k] - tr_cx[k]) ** 2 + (tr_y[k] - tr_cy[k]) ** 2)
                        tr_static[k] = ds < D_stat
                        tr_cx[k] = tr_x[k]; tr_cy[k] = tr_y[k]; tr_ct[k] = ti
                    if (not tr_conf[k]) and tr_hits[k] >= H_min and \
                            ti - tr_t0[k] >= T_conf and tr_dmax[k] >= D_min:
                        tr_conf[k] = True
                        n_confirm += 1
                else:
                    # spawn: free slot, else replace stalest unconfirmed track
                    slot = -1
                    for k in range(NT):
                        if not tr_on[k]:
                            slot = k
                            break
                    if slot < 0:
                        old = ti
                        for k in range(NT):
                            if (not tr_conf[k]) and tr_tu[k] < old:
                                old = tr_tu[k]; slot = k
                    if slot >= 0:
                        k = slot
                        tr_on[k] = True; tr_conf[k] = False
                        tr_x[k] = xi; tr_y[k] = yi; tr_vx[k] = 0.0; tr_vy[k] = 0.0
                        tr_tu[k] = ti; tr_ax[k] = xi; tr_ay[k] = yi; tr_at[k] = ti
                        tr_hits[k] = 1; tr_t0[k] = ti; tr_x0[k] = xi; tr_y0[k] = yi
                        tr_dmax[k] = 0.0
                        tr_cx[k] = xi; tr_cy[k] = yi; tr_ct[k] = ti; tr_static[k] = False
                        assign[i] = 100 + k
            # ---- 6. labelling
            if (not lab_baf) or baf:
                for k in range(NT):
                    if tr_on[k] and tr_conf[k] and (not tr_static[k]) and ti - tr_tu[k] <= T_lab:
                        dtk = ti - tr_tu[k]
                        px_ = tr_x[k] + tr_vx[k] * dtk
                        py_ = tr_y[k] + tr_vy[k] * dtk
                        ex = R_lab + k_vlab * abs(tr_vx[k]) * T_lab
                        ey = R_lab + k_vlab * abs(tr_vy[k]) * T_lab
                        if abs(xi - px_) <= ex and abs(yi - py_) <= ey:
                            pred[i] = 1
                            break
        else:
            pred[i] = cand

    return pred, baf_out, resp_out, cand_out, n_confirm, assign


def run(seq_or_arrays, params: Params):
    """Run the detector. Accepts a data.Sequence or (x, y, t_us, p)."""
    if hasattr(seq_or_arrays, "t_us"):
        s = seq_or_arrays
        x, y, t, p = s.x, s.y, s.t_us, s.p
    else:
        x, y, t, p = seq_or_arrays
    P = np.array([float(getattr(params, k)) for k in KEYS], dtype=np.float64)
    pred, baf, resp, cand, nconf, assign = _run(
        np.ascontiguousarray(x, np.int64), np.ascontiguousarray(y, np.int64),
        np.ascontiguousarray(t, np.int64), np.ascontiguousarray(p, np.int64), P)
    return {"pred": pred.astype(bool), "baf": baf.astype(bool),
            "resp": resp.astype(bool), "cand": cand.astype(bool), "n_confirm": int(nconf),
            "assign": assign}
