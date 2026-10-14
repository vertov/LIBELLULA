import sys, json
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
import numpy as np
from libstmd import data, model, metrics
seqs = data.load_dir(sys.argv[1])
P = model.Params(**(json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}))
print(f"{'seq':13}{'IoU':>6}{'ACC':>6}{'Pd':>6}{'prec':>6}{'fc/w':>7}{'conf':>5}  tgt: baf resp cand | bg: baf resp cand")
for s in seqs:
    o = model.run(s, P); m = metrics.EvUAVMetrics(); m.update(s.t_ms, s.x, s.y, s.label, s.ident, o["pred"]); r = m.result()
    g = s.label > 0
    f = lambda a, k: a[k].mean() if k.any() else 0
    print(f"{s.name:13}{r['IoU']:6.2f}{r['ACC']:6.2f}{r['Pd']:6.2f}{r['precision']:6.2f}{r['false_clusters_per_window']:7.2f}{o['n_confirm']:5d}"
          f"  {f(o['baf'],g):.2f} {f(o['resp'],g):.2f} {f(o['cand'],g):.2f} | {f(o['baf'],~g):.2f} {f(o['resp'],~g):.3f} {f(o['cand'],~g):.4f}")
