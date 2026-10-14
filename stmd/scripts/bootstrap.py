"""95% bootstrap intervals over sequences for a frozen config on one split."""
import sys, json
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
import numpy as np
from libstmd import data, model, metrics
from libstmd.pool import pooled
cfg = json.load(open(sys.argv[1])); P = model.Params(**cfg)
seqs = data.load_dir(sys.argv[2]); per = {}
for s in seqs:
    o = model.run(s, P); m = metrics.EvUAVMetrics(); m.update(s.t_ms, s.x, s.y, s.label, s.ident, o["pred"]); r = m.result()
    per[s.name] = [r["tp"], r["fp"], r["fn"], m.obj_num, m.correct_num, m.false_num, m.frame_num]
names = list(per); rng = np.random.default_rng(0)
B = [pooled(per, list(rng.choice(names, len(names)))) for _ in range(2000)]
point = pooled(per, names)
for k in ("IoU", "ACC", "Pd", "precision"):
    v = np.array([b[k] for b in B]); lo, hi = np.percentile(v, [2.5, 97.5])
    print(f"{k:9} {point[k]:.3f}  95% CI [{lo:.3f}, {hi:.3f}]")
