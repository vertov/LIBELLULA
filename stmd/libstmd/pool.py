"""Pool per-sequence raw counts (from scripts/tune.py) into metrics.
Rows: [tp, fp, fn, obj, cor, fal, frames] (+ v26: [n_targets, n_detected,
cov_present, cov_hit, false_uids, total_uids, rec_windows, rec_windows_false,
dur_min])."""
import os
import numpy as np

W, H = 346, 260
FALSE_TRACK_BUDGET_PER_MIN = float(os.environ.get("FT_BUDGET", "2.0"))


def pooled(per: dict, names) -> dict:
    a = np.array([per[n] for n in names], dtype=float).sum(axis=0)
    tp, fp, fn, obj, cor, fal, frames = a[:7]
    out = {
        "IoU": tp / max(1, tp + fp + fn),
        "ACC": tp / max(1, tp + fn),
        "Pd": cor / max(1, obj),
        "Fa": fal / max(1, frames * W * H),
        "precision": tp / max(1, tp + fp),
        "false_clusters_per_window": fal / max(1, frames),
    }
    if len(a) >= 16:
        nt, nd, cp, ch, fu, tu, rw, rwf, dm = a[7:16]
        out.update({
            "target_detected_rate": nd / max(1, nt),
            "window_coverage": ch / max(1, cp),
            "false_tracks_per_min": fu / max(1e-9, dm),
            "false_track_time_frac": rwf / max(1, rw),
        })
    return out


def objective(r: dict, kind: str = None) -> float:
    kind = kind or os.environ.get("OBJECTIVE", "seg")
    if kind == "seg":
        return r["IoU"] + r["Pd"]
    if kind == "alarm":
        # track detection subject to a false-track budget (per minute of data);
        # configurations over budget are penalised in proportion
        over = max(0.0, r["false_tracks_per_min"] - FALSE_TRACK_BUDGET_PER_MIN)
        return r["window_coverage"] + r["target_detected_rate"] - 0.1 * over
    raise ValueError(kind)
