"""Ground-truth statistics for EV-UAV test: per-target size, speed, and
opposite-polarity timing at the same pixel (target vs background)."""
import sys, glob, numpy as np
from collections import defaultdict

W, H = 346, 260
def opp_dt(x, y, t, p, sel):
    """For selected events, time since last opposite-polarity event at same pixel."""
    last = np.full((2, H, W), -1e9)
    out = np.full(len(t), np.nan)
    for i in range(len(t)):
        q = p[i]
        if sel[i]:
            lo = last[1 - q, y[i], x[i]]
            if lo > -1e8: out[i] = t[i] - lo
        last[q, y[i], x[i]] = t[i]
    return out

rows = []
dt_tgt, dt_bg, order = [], [], defaultdict(int)
for f in sorted(glob.glob(sys.argv[1] + "/*.npz")):
    ev = np.load(f)["ev"]
    x, y, t, p, lab, nm = (ev[k].astype(np.int64) if k != "t" else ev[k] for k in ("x","y","t","p","label","name"))
    pos = lab > 0
    sizes, speeds = [], []
    for tid in np.unique(nm[pos]):
        m = pos & (nm == tid)
        tt = t[m]; xx = x[m]; yy = y[m]
        cents = []
        for w0 in np.arange(tt.min(), tt.max(), 50.0):
            k = (tt >= w0) & (tt < w0 + 50)
            if k.sum() >= 3:
                sizes.append(max(np.ptp(xx[k]), np.ptp(yy[k])) + 1)
                cents.append((w0, xx[k].mean(), yy[k].mean()))
        for a, b in zip(cents[:-1], cents[1:]):
            if b[0] - a[0] == 50:
                speeds.append(np.hypot(b[1]-a[1], b[2]-a[2]) / 50.0)  # px/ms
    rng = np.random.default_rng(0)
    bg_sel = (~pos) & (rng.random(len(t)) < min(1.0, 20000 / max(1, (~pos).sum())))
    d = opp_dt(x, y, t, p, pos | bg_sel)
    dt_tgt.append(d[pos]); dt_bg.append(d[bg_sel])
    rows.append((f.split('/')[-1], len(t), pos.sum(), len(np.unique(nm[pos])),
                 np.median(sizes) if sizes else np.nan, np.percentile(sizes, 90) if sizes else np.nan,
                 np.median(speeds) if speeds else np.nan))
print(f"{'file':12} {'events':>7} {'tgt':>6} {'ids':>3} {'size_med':>8} {'size_p90':>8} {'speed_px/ms':>11}")
for r in rows: print(f"{r[0]:12} {r[1]:>7} {r[2]:>6} {r[3]:>3} {r[4]:8.1f} {r[5]:8.1f} {r[6]:11.3f}")
dt_tgt = np.concatenate(dt_tgt); dt_bg = np.concatenate(dt_bg)
for name, d in (("target", dt_tgt), ("background", dt_bg)):
    have = ~np.isnan(d)
    q = np.percentile(d[have], [10, 25, 50, 75, 90]) if have.any() else []
    print(f"{name:10}: frac with prior opposite-polarity event at same pixel = {have.mean():.2f}; "
          f"dt percentiles (ms) 10/25/50/75/90 = {np.round(q,1).tolist()}; frac dt<30ms = {(d[have]<30).mean():.2f}")
