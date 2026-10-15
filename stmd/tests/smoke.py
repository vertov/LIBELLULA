"""Data-free smoke test: a synthetic 5x5 dark target crossing a noisy 346x260
sensor. Checks that the model compiles and finds the target with the selected
configuration. Not a performance claim. Exit code 1 on failure."""
import os, sys, json
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import numpy as np
from libstmd import model

W, H = 346, 260
rng = np.random.default_rng(1)
T_ms = 3000
# background shot noise, 0.1 events/pixel/s
n_noise = int(0.1 * W * H * T_ms / 1000)
ev = [np.stack([rng.integers(0, W, n_noise), rng.integers(0, H, n_noise),
                rng.integers(0, T_ms * 1000, n_noise), rng.integers(0, 2, n_noise),
                np.zeros(n_noise, int)], 1)]
# 5x5 dark square moving +x at 0.05 px/ms from (60,120): OFF at the leading
# edge column, ON at the trailing edge column, each ~6 events/ms jittered
x0, y0, v, size = 60.0, 120, 0.05, 5
for t in range(0, T_ms):
    lead = int(x0 + v * t) + size
    trail = int(x0 + v * t)
    for col, pol in ((lead, 0), (trail, 1)):
        if rng.random() < 0.6:
            yy = y0 + rng.integers(0, size, 2)
            ev.append(np.stack([np.full(2, col), yy, t * 1000 + rng.integers(0, 1000, 2),
                                np.full(2, pol), np.ones(2, int)], 1))
ev = np.concatenate(ev)
ev = ev[np.argsort(ev[:, 2], kind="stable")]
x, y, t, p, lab = (ev[:, i] for i in range(5))
cfg = json.load(open(os.path.join(ROOT, "configs", "selected.json")))
out = model.run((x, y, t, p), model.Params(**cfg))
pred, g = out["pred"], lab > 0
late = t > 500_000           # allow 0.5 s for track confirmation
recall = (pred & g & late).sum() / max(1, (g & late).sum())
precision = (pred & g).sum() / max(1, pred.sum())
print(f"smoke: events={len(t)} target={g.sum()} recall(after 0.5 s)={recall:.2f} precision={precision:.2f}")
# Thresholds mark clear breakage only, not performance.
ok = recall > 0.4 and precision > 0.9
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
