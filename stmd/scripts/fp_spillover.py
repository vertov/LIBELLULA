"""Where do false-positive events sit relative to the true target?
Share of FP events within 10 px of a ground-truth target event in the same 50 ms window."""
import sys, json
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
import numpy as np
from libstmd import data, model, metrics
cfg = json.load(open(sys.argv[1])); cfg.update(json.loads(sys.argv[2])); P = model.Params(**cfg)
for f in sys.argv[3:]:
    s = data.load(f); o = model.run(s, P); g = s.label > 0; fp = o["pred"] & ~g
    m = metrics.EvUAVMetrics(); m.update(s.t_ms, s.x, s.y, s.label, s.ident, o["pred"]); r = m.result()
    win = s.t_ms // 50; near = 0
    for w in np.unique(win[fp]):
        k = fp & (win == w); tg = g & (win == w)
        if not tg.any(): continue
        dx = np.abs(s.x[k][:, None] - s.x[tg][None, :]).min(1); dy = np.abs(s.y[k][:, None] - s.y[tg][None, :]).min(1)
        near += int(((np.maximum(dx, 0) <= 10) & (dy <= 10)).sum())
    print(f"{s.name:13} IoU={r['IoU']:.3f} ACC={r['ACC']:.3f} Pd={r['Pd']:.3f} prec={r['precision']:.3f} fc/w={r['false_clusters_per_window']:.2f}  FP={fp.sum()} within10px_of_target={near/max(1,fp.sum()):.2f}")
