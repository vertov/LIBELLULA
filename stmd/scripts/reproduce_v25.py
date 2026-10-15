"""T0: reproduce the v25 train and val numbers stored in results/final_v25.json.
Does not touch test. usage: reproduce_v25.py TRAIN_DIR VAL_DIR"""
import os, sys, json
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from libstmd import data, model, metrics
stored = json.load(open(os.path.join(ROOT, "results", "final_v25.json")))["v25 selected (train+val-tuned)"]
P = model.Params(**stored["config"])
ok = True
for sp, d in (("train", sys.argv[1]), ("val", sys.argv[2])):
    m = metrics.EvUAVMetrics()
    for s in data.load_dir(d):
        o = model.run(s, P); m.update(s.t_ms, s.x, s.y, s.label, s.ident, o["pred"])
    r = m.result()
    for k in ("IoU", "ACC", "Pd", "precision"):
        same = abs(r[k] - stored[sp][k]) < 1e-9
        ok &= same
        print(f"{sp:5} {k:9} now={r[k]:.6f} stored={stored[sp][k]:.6f} {'ok' if same else 'DIFF'}")
print("REPRODUCED" if ok else "MISMATCH")
