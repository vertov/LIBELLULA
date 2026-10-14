"""EV-UAV evaluation metrics, ported from the authors' utils/eval.py
(github.com/ChenYichen9527/Ev-UAV, configs/evisseg_evuav.yaml: pd_detT=50,
correct_thresh=0.0001, decision threshold 0.9).

Definitions as implemented there:
  IoU  event-level IoU of the target class over all test events pooled.
  ACC  fraction of ground-truth target events predicted as target (recall).
  Pd   per 50 ms window, per target identity present in the window: the
       target counts as detected if >= correct_thresh of its events are
       predicted target (with 0.0001 this means at least one event).
  Fa   per window, false-positive events are rasterised to a 346x260 mask and
       8-connected components counted; Fa = components / (windows * 346*260).

Quirks reproduced deliberately so numbers are comparable: windows use strict
inequalities on integer-ms timestamps (events at exact multiples of 50 ms are
skipped), the window count for Fa is int(span/50) while the loop runs
int(span/50)+1 windows, and the false mask is uint8 (counts wrap at 256).
"""
from __future__ import annotations

import numpy as np
from scipy import ndimage

W, H = 346, 260
_STRUCT8 = np.ones((3, 3), dtype=bool)


class EvUAVMetrics:
    def __init__(self, pd_detT: int = 50, correct_thresh: float = 1e-4):
        self.pd_detT = pd_detT
        self.correct_thresh = correct_thresh
        self.gt, self.pred = [], []
        self.obj_num = 0
        self.correct_num = 0
        self.false_num = 0
        self.frame_num = 0
        self.whole_ev_num = 0

    def update(self, ts_ms: np.ndarray, x: np.ndarray, y: np.ndarray,
               gt: np.ndarray, ident: np.ndarray, pred: np.ndarray) -> None:
        """ts_ms: integer-ms timestamps (ev_loc[:,2]); pred: bool/0-1 array."""
        pred = np.asarray(pred).astype(bool)
        gt = np.asarray(gt).astype(bool)
        self.gt.append(gt)
        self.pred.append(pred)
        self.whole_ev_num += len(ts_ms)
        span = int((ts_ms.max() - ts_ms.min()) / self.pd_detT)
        self.frame_num += span
        # bucket events by window once instead of masking per window
        T = self.pd_detT
        win = ts_ms // T
        on_boundary = (ts_ms % T) == 0          # excluded by strict inequalities
        keep = ~on_boundary & (win <= span)
        order = np.argsort(win[keep], kind="stable")
        idx_keep = np.nonzero(keep)[0][order]
        wins = win[idx_keep]
        bounds = np.searchsorted(wins, np.arange(span + 2))
        for i in range(span + 1):
            sel = idx_keep[bounds[i]:bounds[i + 1]]
            if sel.size == 0:
                continue
            g, pr, idn = gt[sel], pred[sel], ident[sel]
            for tid in np.unique(idn):
                if tid == 0:
                    continue
                m = idn == tid
                self.obj_num += 1
                n_lab = g[m].sum()
                n_cor = (pr[m] == g[m]).sum()      # as in the reference code
                if n_lab > 0 and n_cor / n_lab >= self.correct_thresh:
                    self.correct_num += 1
            fp = sel[pr & ~g]
            if fp.size:
                cnt = np.zeros((H, W), dtype=np.int64)
                np.add.at(cnt, (y[fp], x[fp]), 1)
                mask = (cnt % 256) > 0              # uint8 wrap in the reference
                _, n = ndimage.label(mask, structure=_STRUCT8)
                self.false_num += n

    def result(self) -> dict:
        gt = np.concatenate(self.gt)
        pr = np.concatenate(self.pred)
        tp = int((gt & pr).sum())
        fp = int((~gt & pr).sum())
        fn = int((gt & ~pr).sum())
        return {
            "IoU": tp / max(1, tp + fp + fn),
            "ACC": tp / max(1, tp + fn),
            "Pd": self.correct_num / max(1, self.obj_num),
            "Fa": self.false_num / max(1, self.frame_num * W * H),
            "precision": tp / max(1, tp + fp),
            "false_clusters_per_window": self.false_num / max(1, self.frame_num),
            "tp": tp, "fp": fp, "fn": fn,
            "events": int(len(gt)), "target_windows": self.obj_num,
        }
