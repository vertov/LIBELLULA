"""Score every frozen (val-tuned) configuration once on val and test.
The selected model is the variant with the highest val objective (IoU + Pd);
test plays no part in that choice.
Writes results/final.json, results/test_perseq.txt; prints markdown tables.
usage: final_eval.py VAL_DIR TEST_DIR"""
import sys, json
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
from libstmd import data, model, metrics
from libstmd.pool import objective

R = __import__("os").path.join(__import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))), "results") + "/"
CONFIGS = [
    ("Full model (all stages)", "config_full.json"),
    ("without ESTMD polarity correlation", "config_abl_no_estmd.json"),
    ("without flicker habituation", "config_abl_no_habituation.json"),
    ("without centre-surround inhibition", "config_abl_no_surround.json"),
    ("without activity term in surround", "config_abl_no_activity_surround.json"),
    ("without stationarity check", "config_abl_no_static.json"),
    ("without tracker (per-event score only)", "config_abl_no_tracker.json"),
    ("density only (no ESTMD, habituation or surround)", "config_abl_density_only.json"),
]
splits = {"val": data.load_dir(sys.argv[1]), "test": data.load_dir(sys.argv[2])}
out, perseq = {}, {}
for name, f in CONFIGS:
    cfg = json.load(open(R + f))
    P = model.Params(**cfg)
    out[name] = {"config": cfg}
    for sp, seqs in splits.items():
        m = metrics.EvUAVMetrics()
        rows = []
        for s in seqs:
            o = model.run(s, P)
            m.update(s.t_ms, s.x, s.y, s.label, s.ident, o["pred"])
            if sp == "test":
                mm = metrics.EvUAVMetrics(); mm.update(s.t_ms, s.x, s.y, s.label, s.ident, o["pred"])
                r = mm.result()
                rows.append(f"{s.name:13} events={len(s.x):7d} IoU={r['IoU']:.3f} ACC={r['ACC']:.3f} "
                            f"Pd={r['Pd']:.3f} prec={r['precision']:.3f} fc/w={r['false_clusters_per_window']:.2f}")
        out[name][sp] = m.result()
        if rows:
            perseq[name] = rows

sel = max((n for n, _ in CONFIGS), key=lambda n: objective(out[n]["val"]))
out["_selected"] = sel
json.dump(out, open(R + "final.json", "w"), indent=1)
open(R + "test_perseq.txt", "w").write(f"# {sel}\n" + "\n".join(perseq[sel]) + "\n")

print(f"Selected on val: {sel}\n")
print("| Variant (each tuned on val) | val IoU | val Pd | test IoU | test ACC | test Pd | test precision | false clusters / 50 ms |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for name, _ in CONFIGS:
    v, t = out[name]["val"], out[name]["test"]
    print(f"| {name}{' (selected)' if name == sel else ''} | {v['IoU']:.3f} | {v['Pd']:.3f} | {t['IoU']:.3f} | "
          f"{t['ACC']:.3f} | {t['Pd']:.3f} | {t['precision']:.3f} | {t['false_clusters_per_window']:.2f} |")
t = out[sel]["test"]
print(f"\nSelected on test: Fa (released scorer) = {t['Fa']:.2e}; events = {t['events']}; target windows = {t['target_windows']}")
