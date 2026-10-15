"""Per-sequence profile for a split: background rate, hot cells (glare
proxy), and current-model scores. usage: split_profile.py CONFIG DIR"""
import sys, json
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
import numpy as np
from multiprocessing import Pool
from libstmd import data, model, metrics
P = model.Params(**json.load(open(sys.argv[1])))
def prof(f):
    s = data.load(f); g = s.label > 0; o = model.run(s, P)
    m = metrics.EvUAVMetrics(); m.update(s.t_ms, s.x, s.y, s.label, s.ident, o["pred"]); r = m.result()
    dur = (s.t_us.max() - s.t_us.min()) / 1e6
    cnt = np.zeros((33, 44)); np.add.at(cnt, (s.y[~g] // 8, s.x[~g] // 8), 1)
    med = np.median(cnt[cnt > 0]) if (cnt > 0).any() else 1
    hot = int((cnt > 20 * med).sum())
    fp = o["pred"] & ~g
    fp_hot = (cnt > 20 * med)[s.y[fp] // 8, s.x[fp] // 8].sum()
    return (s.name, len(s.x), (~g).sum() / dur / 346 / 260, hot, r["IoU"], r["ACC"], r["Pd"], r["precision"],
            r["tp"], r["fp"], r["fn"], int(fp.sum()), int(fp_hot))
import glob
files = sorted(glob.glob(sys.argv[2] + "/*.npz"))
with Pool(2) as pool:
    rows = pool.map(prof, files)
print(f"{'seq':14}{'events':>8}{'bg/px/s':>8}{'hot':>5}{'IoU':>6}{'ACC':>6}{'Pd':>6}{'prec':>6}{'FP':>7}{'FPhot':>7}")
for r in rows:
    print(f"{r[0]:14}{r[1]:8d}{r[2]:8.2f}{r[3]:5d}{r[4]:6.2f}{r[5]:6.2f}{r[6]:6.2f}{r[7]:6.2f}{r[11]:7d}{r[12]:7d}")
tp, fp, fn = (sum(r[i] for r in rows) for i in (8, 9, 10))
print(f"pooled IoU {tp/(tp+fp+fn):.3f}  FP {fp}  FP in hot cells {sum(r[12] for r in rows)}")
