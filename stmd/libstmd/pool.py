"""Pool per-sequence raw counts (from scripts/tune.py) into EV-UAV metrics."""
import numpy as np

W, H = 346, 260


def pooled(per: dict, names) -> dict:
    a = np.array([per[n] for n in names], dtype=float).sum(axis=0)
    tp, fp, fn, obj, cor, fal, frames = a
    return {
        "IoU": tp / max(1, tp + fp + fn),
        "ACC": tp / max(1, tp + fn),
        "Pd": cor / max(1, obj),
        "Fa": fal / max(1, frames * W * H),
        "precision": tp / max(1, tp + fp),
        "false_clusters_per_window": fal / max(1, frames),
    }


def objective(r: dict) -> float:
    return r["IoU"] + r["Pd"]
