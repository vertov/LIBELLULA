"""Random-search tuning with per-sequence raw counts, so any pooling (folds,
held-out sets) can be computed afterwards without re-running.

usage: tune.py DATA_DIR OUT.jsonl N_CONFIGS [SEED] [BASE_JSON|-] [SPREAD] [FIXED_JSON]
"""
import sys, json, random, time
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
from multiprocessing import Pool
import numpy as np
from libstmd import data, model, metrics

SPACE = {
    "T_ba_ms": [10, 20, 40, 60, 80],
    "F_max": [2, 3, 5],
    "tau_flip_ms": [500, 1000, 2000],
    "tau_min_ms": [0.5, 1, 3],
    "tau_max_ms": [50, 100, 200, 400, 800],
    "nb_radius": [0, 1],
    "estmd_gate": [True, False],
    "w_estmd": [0.5, 1, 2, 4],
    "cell": [2, 3, 4, 6],
    "tau_acc_ms": [50, 100, 200, 400],
    "surround_r": [2, 3, 4, 5, 6],
    "k_inh": [0.5, 1, 2, 4, 6, 8],
    "k_act": [0, 0.25, 0.5, 1, 2, 3, 4],
    "theta": [1, 1.5, 2, 3, 4, 6],
    "gate_px": [6, 8, 12, 16, 24],
    "alpha": [0.1, 0.2, 0.4],
    "H_min": [3, 5, 8, 12, 16, 20],
    "T_conf_ms": [0, 50, 100, 200],
    "D_min_px": [1, 2, 3, 5],
    "T_dead_ms": [200, 300, 500, 1000],
    "T_stat_ms": [300, 500, 1000],
    "D_stat_px": [2, 3, 5, 8],
    "R_lab_px": [3, 4, 6, 8, 10],
    "T_lab_ms": [50, 100, 200, 400, 600, 800],
    "lab_requires_baf": [False, True],
    "k_vlab": [0, 0.5, 1],
}

SEQS = None


def _init(folder):
    global SEQS
    SEQS = data.load_dir(folder)


def evaluate(cfg):
    P = model.Params(**cfg)
    per = {}
    for s in SEQS:
        o = model.run(s, P)
        m = metrics.EvUAVMetrics()
        m.update(s.t_ms, s.x, s.y, s.label, s.ident, o["pred"])
        r = m.result()
        per[s.name] = [r["tp"], r["fp"], r["fn"], m.obj_num, m.correct_num, m.false_num, m.frame_num]
    return {"cfg": cfg, "per": per}


def sample(rng, base=None, spread=1.0):
    cfg = {}
    for k, vals in SPACE.items():
        if base is not None and k in base and rng.random() > spread:
            cfg[k] = base[k]
        else:
            cfg[k] = rng.choice(vals)
    return cfg


if __name__ == "__main__":
    folder, out, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
    seed = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    base = json.loads(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5] != "-" else None
    spread = float(sys.argv[6]) if len(sys.argv) > 6 else 1.0
    rng = random.Random(seed)
    cfgs = [sample(rng, base, spread) for _ in range(n)]
    if base is not None:
        cfgs[0] = {k: base.get(k, cfgs[0][k]) for k in SPACE}
    fixed = json.loads(sys.argv[7]) if len(sys.argv) > 7 else {}
    for c in cfgs:
        c.update(fixed)
    t0 = time.time()
    with Pool(2, initializer=_init, initargs=(folder,)) as pool, open(out, "a") as fh:
        for i, res in enumerate(pool.imap_unordered(evaluate, cfgs)):
            fh.write(json.dumps(res) + "\n"); fh.flush()
            if (i + 1) % 25 == 0:
                print(f"{i+1}/{n} {time.time()-t0:.0f}s", flush=True)
