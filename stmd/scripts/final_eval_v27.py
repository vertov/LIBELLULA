"""v27 held-out evaluation (ride-alongs). Scores each configuration ONCE on the
held-out split with both scorers and 95 % bootstrap intervals, following
final_eval_v26.py. Variants: v26 segmentation (reference, same numbers as
final_v26.json), the v27 seg_ft refinement (segmentation objective with a
false-track penalty, searched on train(79)+val), and both without the ESTMD
stage (saves the per-polarity timestamp memory, 2 x 2 bytes per pixel).
usage: final_eval_v27.py TRAIN_DIR   (writes results/final_v27.json, prints markdown)"""
import os, sys, json
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import numpy as np
from libstmd import data, model, metrics, trackmetrics
from libstmd.pool import pooled
from scripts.eval_split import load_names

R = os.path.join(ROOT, "results"); C = os.path.join(ROOT, "configs")
seg = json.load(open(os.path.join(C, "v26_segmentation.json")))
segft = json.load(open(os.path.join(C, "v27_segmentation_ft.json")))
VARIANTS = [
    ("v26 segmentation (reference)", seg),
    ("v26 segmentation, no ESTMD", {**seg, "use_estmd": False}),
    ("v27 segmentation+ft", segft),
    ("v27 segmentation+ft, no ESTMD", {**segft, "use_estmd": False}),
]
hold = load_names(os.path.join(ROOT, "splits", "holdout_v26.txt"))
seqs = [s for s in data.load_dir(sys.argv[1]) if s.name in hold]
rng = np.random.default_rng(0)
out = {}
for name, cfg in VARIANTS:
    P = model.Params(**cfg); per = {}; rows = []
    for s in seqs:
        o = model.run(s, P)
        m = metrics.EvUAVMetrics(); m.update(s.t_ms, s.x, s.y, s.label, s.ident, o["pred"]); r = m.result()
        tm = trackmetrics.TrackMetrics(); tm.update(s, o["tracks"]); t = tm.result()
        per[s.name] = [r["tp"], r["fp"], r["fn"], m.obj_num, m.correct_num, m.false_num, m.frame_num,
                       tm.n_targets, tm.n_detected, tm.cov_present, tm.cov_hit, tm.false_uids, tm.total_uids,
                       tm.rec_windows, tm.rec_windows_false, tm.dur_min]
        rows.append({"seq": s.name, "IoU": r["IoU"], "Pd": r["Pd"], "precision": r["precision"],
                     "fc_w": r["false_clusters_per_window"], "det": t["target_detected_rate"],
                     "cov": t["window_coverage"], "ft_min": t["false_tracks_per_min"], "loc": t["loc_error_px_median"]})
    names = list(per); point = pooled(per, names)
    boots = [pooled(per, list(rng.choice(names, len(names)))) for _ in range(2000)]
    ci = {k: [float(np.percentile([b[k] for b in boots], 2.5)), float(np.percentile([b[k] for b in boots], 97.5))]
          for k in ("IoU", "Pd", "window_coverage", "false_tracks_per_min", "target_detected_rate")}
    out[name] = {"config": cfg, "pooled": point, "ci95": ci, "perseq": rows}
json.dump(out, open(os.path.join(R, "final_v27.json"), "w"), indent=1)

def f(x): return f"{x:.3f}"
print("| Variant (held-out, 20 train sequences) | IoU | Pd | precision | false clusters/50 ms | target detected | window coverage | false tracks/min |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for name, _ in VARIANTS:
    p, c = out[name]["pooled"], out[name]["ci95"]
    print(f"| {name} | {f(p['IoU'])} [{f(c['IoU'][0])}–{f(c['IoU'][1])}] | {f(p['Pd'])} [{f(c['Pd'][0])}–{f(c['Pd'][1])}] | {f(p['precision'])} | "
          f"{p['false_clusters_per_window']:.2f} | {f(p['target_detected_rate'])} | {f(p['window_coverage'])} [{f(c['window_coverage'][0])}–{f(c['window_coverage'][1])}] | "
          f"{p['false_tracks_per_min']:.2f} [{c['false_tracks_per_min'][0]:.1f}–{c['false_tracks_per_min'][1]:.1f}] |")
