import sys, json
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
import numpy as np
from libstmd import data, model
P = model.Params(**(json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}))
rows = []   # (n_events_in_window, detected, ms_since_target_first_seen)
for s in data.load_dir(sys.argv[1]):
    o = model.run(s, P)
    first = {}
    for tid in np.unique(s.ident[s.ident > 0]):
        first[tid] = s.t_ms[s.ident == tid].min()
    win = s.t_ms // 50
    ok = (s.t_ms % 50) != 0
    for tid in first:
        m = (s.ident == tid) & ok
        for w in np.unique(win[m]):
            k = m & (win == w)
            rows.append((k.sum(), o["pred"][k].any(), w * 50 - first[tid]))
r = np.array(rows, dtype=float)
print("windows", len(r), "Pd", r[:, 1].mean().round(3))
for lo, hi in ((1, 2), (3, 5), (6, 10), (11, 20), (21, 1e9)):
    m = (r[:, 0] >= lo) & (r[:, 0] <= hi)
    print(f"  events/window {lo:>3}-{hi if hi < 1e9 else 'inf':>3}: n={int(m.sum()):5d} share={m.mean():.2f} Pd={r[m,1].mean():.2f}")
for lo, hi in ((0, 200), (200, 500), (500, 1000), (1000, 1e9)):
    m = (r[:, 2] >= lo) & (r[:, 2] < hi)
    print(f"  age {lo:>5}-{hi if hi < 1e9 else 'inf':>5} ms: n={int(m.sum()):5d} Pd={r[m,1].mean():.2f}")
