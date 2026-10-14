import sys, json, gzip
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
from libstmd.pool import pooled, objective
rows = [json.loads(l) for f in sys.argv[1:] for l in (gzip.open(f, "rt") if f.endswith(".gz") else open(f))]
scored = []
for r in rows:
    m = pooled(r["per"], list(r["per"].keys()))
    scored.append((objective(m), m, r["cfg"]))
scored.sort(key=lambda z: -z[0])
for obj, m, cfg in scored[:8]:
    print(f"obj={obj:.3f} IoU={m['IoU']:.3f} ACC={m['ACC']:.3f} Pd={m['Pd']:.3f} prec={m['precision']:.3f} fc/w={m['false_clusters_per_window']:.2f}")
print(json.dumps(scored[0][2]))
