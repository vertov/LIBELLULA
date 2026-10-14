import sys, time, json
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
import numpy as np
from libstmd import data, model, metrics

seqs = data.load_dir(sys.argv[1])
overrides = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}

# metric sanity: trivial predictors
for name, fn in (("all-target", lambda s: np.ones(len(s.x), bool)),
                 ("oracle", lambda s: s.label > 0),
                 ("none", lambda s: np.zeros(len(s.x), bool))):
    m = metrics.EvUAVMetrics()
    for s in seqs:
        m.update(s.t_ms, s.x, s.y, s.label, s.ident, fn(s))
    r = m.result()
    print(f"{name:11} IoU={r['IoU']:.4f} ACC={r['ACC']:.4f} Pd={r['Pd']:.4f} Fa={r['Fa']:.2e} fc/win={r['false_clusters_per_window']:.2f}")

P = model.Params(**overrides)
m = metrics.EvUAVMetrics()
stage = np.zeros((2, 4))   # rows: target, background; cols: total, baf, resp, cand
t0 = time.time()
for s in seqs:
    out = model.run(s, P)
    g = s.label > 0
    for r_, msk in ((0, g), (1, ~g)):
        stage[r_] += [msk.sum(), out["baf"][msk].sum(), out["resp"][msk].sum(), out["cand"][msk].sum()]
    m.update(s.t_ms, s.x, s.y, s.label, s.ident, out["pred"])
dt = time.time() - t0
r = m.result()
print(f"model       IoU={r['IoU']:.4f} ACC={r['ACC']:.4f} Pd={r['Pd']:.4f} Fa={r['Fa']:.2e} "
      f"prec={r['precision']:.3f} fc/win={r['false_clusters_per_window']:.3f}  ({dt:.1f}s)")
for lab, row in (("target", stage[0]), ("background", stage[1])):
    print(f"  {lab:10} pass BAF {row[1]/row[0]:.3f}  resp {row[2]/row[0]:.3f}  cand {row[3]/row[0]:.4f}")
