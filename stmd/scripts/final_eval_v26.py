"""v26 held-out evaluation. Scores each configuration ONCE on the held-out
split (20 train sequences never used for tuning) with both scorers, with
95 % bootstrap intervals over sequences for the headline numbers, plus
no-retune ablations of the v26 configurations.
usage: final_eval_v26.py TRAIN_DIR   (writes results/final_v26.json, prints markdown)"""
import os, sys, json
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import numpy as np
from libstmd import data, model, metrics, trackmetrics
from libstmd.pool import pooled
from scripts.eval_split import load_names

R = os.path.join(ROOT, "results"); C = os.path.join(ROOT, "configs")
v25 = json.load(open(os.path.join(C, "selected_v25.json")))
seg = json.load(open(os.path.join(C, "v26_segmentation.json")))
alarm = json.load(open(os.path.join(C, "v26_alarm.json")))
VARIANTS = [
    ("v25 (previous release)", v25),
    ("v26 segmentation", seg),
    ("v26 segmentation, coarse surround k=3 (no re-tune)", {**seg, "sur_mode": 1, "sur_k": 3}),
    ("v26 segmentation, no glare adaptation", {**seg, "use_glare": False}),
    ("v26 segmentation, no noise adaptation", {**seg, "use_noise_adapt": False}),
    ("v26 alarm", alarm),
    ("v26 alarm, coarse surround k=3 (no re-tune)", {**alarm, "sur_mode": 1, "sur_k": 3}),
    ("v26 alarm, no glare adaptation", {**alarm, "use_glare": False}),
    ("v26 alarm, no noise adaptation", {**alarm, "use_noise_adapt": False}),
    ("v26 alarm, lab_requires_baf toggled", {**alarm, "lab_requires_baf": not alarm.get("lab_requires_baf", False)}),
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
json.dump(out, open(os.path.join(R, "final_v26.json"), "w"), indent=1)

def f(x): return f"{x:.3f}"
print("| Variant (held-out, 20 train sequences) | IoU | Pd | precision | false clusters/50 ms | target detected | window coverage | false tracks/min |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for name, _ in VARIANTS:
    p, c = out[name]["pooled"], out[name]["ci95"]
    print(f"| {name} | {f(p['IoU'])} [{f(c['IoU'][0])}–{f(c['IoU'][1])}] | {f(p['Pd'])} [{f(c['Pd'][0])}–{f(c['Pd'][1])}] | {f(p['precision'])} | "
          f"{p['false_clusters_per_window']:.2f} | {f(p['target_detected_rate'])} | {f(p['window_coverage'])} [{f(c['window_coverage'][0])}–{f(c['window_coverage'][1])}] | "
          f"{p['false_tracks_per_min']:.2f} [{c['false_tracks_per_min'][0]:.1f}–{c['false_tracks_per_min'][1]:.1f}] |")
print()
hard = [n for n in hold if any(k in open(os.path.join(ROOT, "splits", "holdout_v26.txt")).read().split(n)[1].split("\n")[0] for k in ("glare", "noise"))]
print("| Hard held-out sequence | v25 IoU / Pd / ft-min | v26 seg IoU / Pd / ft-min | v26 alarm IoU / Pd / ft-min | v26 alarm cov |")
print("|---|---|---|---|---:|")
for n in sorted(hard):
    r = {k: next(x for x in out[k]["perseq"] if x["seq"] == n) for k in ("v25 (previous release)", "v26 segmentation", "v26 alarm")}
    a, b, c = r["v25 (previous release)"], r["v26 segmentation"], r["v26 alarm"]
    print(f"| {n} | {a['IoU']:.2f} / {a['Pd']:.2f} / {a['ft_min']:.1f} | {b['IoU']:.2f} / {b['Pd']:.2f} / {b['ft_min']:.1f} | {c['IoU']:.2f} / {c['Pd']:.2f} / {c['ft_min']:.1f} | {c['cov']:.2f} |")
