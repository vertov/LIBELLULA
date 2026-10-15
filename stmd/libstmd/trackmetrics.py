"""Track-level (detection) metrics for the small-target detector.

The EV-UAV scorer (metrics.py) is event-segmentation oriented: a stray noise
pixel labelled target is a separate false alarm. A user of a detector asks
different questions, answered here from the model's confirmed-track log
(model.run(...)["tracks"]) and the ground-truth target events.

Definitions (see docs/TRACK_METRICS.md):

  Ground truth. Each target identity (name field) is summarised per 50 ms
  window by the centroid of its labelled events in that window. A target is
  "present" in a window if it has >= MIN_GT_EVENTS labelled events there.

  Match. A track record (t, uid, x, y) matches a target if, in the record's
  50 ms window, the target is present and |x - cx| <= GATE and |y - cy| <= GATE
  (Chebyshev, px).

  target_detected_rate   fraction of target identities with >= 1 matching
                         track record at any time.
  time_to_first_detect   per detected target: first matching record time
                         minus the target's first labelled event time (ms);
                         reported as median over detected targets.
  window_coverage        fraction of (target, window) pairs where the target
                         is present and some matching record exists in that
                         window. Track-level analogue of Pd.
  false_tracks_per_min   confirmed track uids with NO matching record in any
                         window, divided by total sequence duration in
                         minutes. (A track that matches at any point is not
                         false, even if it later drifts.)
  false_track_time_frac  fraction of all track-record windows (uid, window)
                         with no match; measures time spent reporting a
                         position that is not a target.
  loc_error_px           Euclidean distance from matching records to the
                         target centroid; median and 90th percentile.
"""
from __future__ import annotations

import numpy as np

GATE = 10.0
WIN_US = 50_000
MIN_GT_EVENTS = 2


class TrackMetrics:
    def __init__(self, gate: float = GATE):
        self.gate = gate
        self.n_targets = 0
        self.n_detected = 0
        self.ttfd = []
        self.cov_present = 0
        self.cov_hit = 0
        self.false_uids = 0
        self.total_uids = 0
        self.rec_windows = 0
        self.rec_windows_false = 0
        self.loc = []
        self.dur_min = 0.0

    def update(self, seq, tracks: dict) -> None:
        x, y, t, lab, ident = seq.x, seq.y, seq.t_us, seq.label, seq.ident
        self.dur_min += (t.max() - t.min()) / 60e6
        g = lab > 0
        win = t // WIN_US
        # ground-truth centroids: dict (tid, w) -> (cx, cy)
        cent = {}
        first_t = {}
        for tid in np.unique(ident[g]):
            m = g & (ident == tid)
            first_t[tid] = int(t[m].min())
            for w in np.unique(win[m]):
                k = m & (win == w)
                if k.sum() >= MIN_GT_EVENTS:
                    cent[(int(tid), int(w))] = (float(x[k].mean()), float(y[k].mean()))
        by_win = {}
        for (tid, w), c in cent.items():
            by_win.setdefault(w, []).append((tid, c))
        self.n_targets += len(first_t)
        self.cov_present += len(cent)

        tt, tu, tx, ty = tracks["t_us"], tracks["uid"], tracks["x"], tracks["y"]
        tw = tt // WIN_US
        uid_hit = {}
        tid_first_hit = {}
        covered = set()
        rec_win_seen = set()
        rec_win_false = set()
        for i in range(len(tt)):
            w = int(tw[i]); u = int(tu[i])
            key = (u, w)
            matched = False
            for tid, (cx, cy) in by_win.get(w, ()):
                if abs(tx[i] - cx) <= self.gate and abs(ty[i] - cy) <= self.gate:
                    matched = True
                    covered.add((tid, w))
                    self.loc.append(float(np.hypot(tx[i] - cx, ty[i] - cy)))
                    if tid not in tid_first_hit or tt[i] < tid_first_hit[tid]:
                        tid_first_hit[tid] = int(tt[i])
            uid_hit[u] = uid_hit.get(u, False) or matched
            if key not in rec_win_seen:
                rec_win_seen.add(key)
                if not matched:
                    rec_win_false.add(key)
            elif matched and key in rec_win_false:
                rec_win_false.discard(key)
        self.cov_hit += len(covered)
        self.total_uids += len(uid_hit)
        self.false_uids += sum(1 for v in uid_hit.values() if not v)
        self.rec_windows += len(rec_win_seen)
        self.rec_windows_false += len(rec_win_false)
        self.n_detected += len(tid_first_hit)
        for tid, th in tid_first_hit.items():
            self.ttfd.append((th - first_t[tid]) / 1000.0)

    def result(self) -> dict:
        loc = np.array(self.loc) if self.loc else np.array([np.nan])
        return {
            "target_detected_rate": self.n_detected / max(1, self.n_targets),
            "time_to_first_detect_ms_median": float(np.median(self.ttfd)) if self.ttfd else float("nan"),
            "window_coverage": self.cov_hit / max(1, self.cov_present),
            "false_tracks_per_min": self.false_uids / max(1e-9, self.dur_min),
            "false_track_time_frac": self.rec_windows_false / max(1, self.rec_windows),
            "loc_error_px_median": float(np.median(loc)),
            "loc_error_px_p90": float(np.percentile(loc, 90)),
            "n_targets": self.n_targets, "n_tracks": self.total_uids,
            "false_tracks": self.false_uids, "duration_min": self.dur_min,
        }
