"""T4: C fixed-point reference vs Python float model on a set of sequences.
Reports per-event agreement per stage and pooled metrics for both.
usage: c_equivalence.py CONFIG.json DIRS [--only FILE] [--exclude FILE]"""
import os, sys, json, argparse
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import numpy as np
from libstmd import data, model, metrics, trackmetrics
from cref import cref
from scripts.eval_split import load_names

ap = argparse.ArgumentParser(); ap.add_argument("config"); ap.add_argument("dirs"); ap.add_argument("--only"); ap.add_argument("--exclude")
a = ap.parse_args()
cfg = json.load(open(a.config)); P = model.Params(**cfg)
only = load_names(a.only) if a.only else None; excl = load_names(a.exclude) if a.exclude else None
agree = {"baf": [0, 0], "habituated": [0, 0], "glare": [0, 0], "resp": [0, 0], "cand": [0, 0], "pred": [0, 0]}
M = {"py": (metrics.EvUAVMetrics(), trackmetrics.TrackMetrics()), "C": (metrics.EvUAVMetrics(), trackmetrics.TrackMetrics())}
for d in a.dirs.split(":"):
    for s in data.load_dir(d):
        if only and s.name not in only: continue
        if excl and s.name in excl: continue
        o = model.run(s, P); c = cref.run(s, cfg, frontend=True); fe = c["frontend"]
        for name, bit, ref in (("baf", 1, o["baf"]), ("resp", 8, o["resp"]), ("cand", 16, o["cand"])):
            agree[name][0] += int((((fe & bit) > 0) == ref).sum()); agree[name][1] += len(fe)
        agree["pred"][0] += int((c["pred"] == o["pred"]).sum()); agree["pred"][1] += len(fe)
        for k, (pr, tr) in (("py", (o["pred"], o["tracks"])), ("C", (c["pred"], c["tracks"]))):
            M[k][0].update(s.t_ms, s.x, s.y, s.label, s.ident, pr); M[k][1].update(s, tr)
print("per-event agreement (C == Python):")
for k in ("baf", "resp", "cand", "pred"):
    print(f"  {k:5} {agree[k][0] / max(1, agree[k][1]):.4f}")
print("pooled metrics:")
for k in ("py", "C"):
    r, t = M[k][0].result(), M[k][1].result()
    print(f"  {k:3} IoU={r['IoU']:.3f} ACC={r['ACC']:.3f} Pd={r['Pd']:.3f} prec={r['precision']:.3f} fc/w={r['false_clusters_per_window']:.2f} | "
          f"det={t['target_detected_rate']:.3f} cov={t['window_coverage']:.3f} ft/min={t['false_tracks_per_min']:.2f} loc={t['loc_error_px_median']:.1f}")
