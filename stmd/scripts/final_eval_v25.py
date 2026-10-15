"""One-time scoring for v25. Compares the v24 selected config with the v25
config (tuned on train+val), plus v25 with each new stage switched off (no
re-tuning). usage: final_eval_v25.py TRAIN_DIR VAL_DIR TEST_DIR"""
import os, sys, json
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from libstmd import data, model, metrics

v24 = json.load(open(os.path.join(ROOT, "configs", "selected_v24.json")))
v25 = json.load(open(os.path.join(ROOT, "results", "config_v25.json")))
VARIANTS = [
    ("v24 selected (val-tuned)", v24),
    ("v25 selected (train+val-tuned)", v25),
    ("v25 without glare adaptation", {**v25, "use_glare": False}),
    ("v25 without noise adaptation", {**v25, "use_noise_adapt": False}),
]
splits = {k: data.load_dir(d) for k, d in zip(("train", "val", "test"), sys.argv[1:4])}
out = {}
for name, cfg in VARIANTS:
    P = model.Params(**cfg); out[name] = {"config": cfg}
    for sp, seqs in splits.items():
        m = metrics.EvUAVMetrics(); per = []
        for s in seqs:
            o = model.run(s, P)
            m.update(s.t_ms, s.x, s.y, s.label, s.ident, o["pred"])
            if sp == "test":
                mm = metrics.EvUAVMetrics(); mm.update(s.t_ms, s.x, s.y, s.label, s.ident, o["pred"]); r = mm.result()
                per.append(f"{s.name:13} IoU={r['IoU']:.3f} ACC={r['ACC']:.3f} Pd={r['Pd']:.3f} prec={r['precision']:.3f} fc/w={r['false_clusters_per_window']:.2f}")
        out[name][sp] = m.result()
        if per: out[name]["test_perseq"] = per
json.dump(out, open(os.path.join(ROOT, "results", "final_v25.json"), "w"), indent=1)
print("| Variant | train IoU | val IoU | test IoU | test ACC | test Pd | test precision | false clusters / 50 ms |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for name, _ in VARIANTS:
    tr, v, t = out[name]["train"], out[name]["val"], out[name]["test"]
    print(f"| {name} | {tr['IoU']:.3f} | {v['IoU']:.3f} | {t['IoU']:.3f} | {t['ACC']:.3f} | {t['Pd']:.3f} | {t['precision']:.3f} | {t['false_clusters_per_window']:.2f} |")
print()
print("\n".join(out["v25 selected (train+val-tuned)"]["test_perseq"]))
