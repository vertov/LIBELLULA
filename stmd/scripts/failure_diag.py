"""Diagnose glare and dense-noise failures for a frozen config.
Glare: share of false-positive events inside persistently hot cells (8x8 px
cells whose whole-sequence background rate is >20x the sequence median).
Noise: local signal-to-noise = target events per 50 ms window vs background
events falling in a target-sized box (12x12 px) around the target per window."""
import sys, json
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
import numpy as np
from libstmd import data, model
P = model.Params(**json.load(open(sys.argv[1])))
for f in sys.argv[2:]:
    s = data.load(f); o = model.run(s, P); g = s.label > 0; pr = o["pred"]
    fp = pr & ~g
    cx, cy = s.x // 8, s.y // 8
    cnt = np.zeros((33, 44)); np.add.at(cnt, (cy[~g], cx[~g]), 1)
    hot = cnt > 20 * np.median(cnt[cnt > 0])
    in_hot = hot[cy, cx]
    # local SNR around targets
    win = s.t_ms // 50; snr = []
    for w in np.unique(win[g]):
        k = g & (win == w)
        if k.sum() < 2: continue
        mx, my = np.median(s.x[k]), np.median(s.y[k])
        b = (~g) & (win == w) & (np.abs(s.x - mx) <= 6) & (np.abs(s.y - my) <= 6)
        snr.append((k.sum(), b.sum()))
    snr = np.array(snr)
    dur = (s.t_us.max() - s.t_us.min()) / 1e6
    print(f"{s.name:12} bg rate {(~g).sum()/dur/346/260:5.2f} ev/px/s | FP events {fp.sum():6d}, in hot cells {fp[in_hot].sum()/max(1,fp.sum()):.2f} "
          f"({hot.sum()} hot cells) | target ev/window median {np.median(snr[:,0]):.0f}, bg ev in 12x12 box median {np.median(snr[:,1]):.0f}, "
          f"ratio {np.median(snr[:,0]/np.maximum(1,snr[:,1])):.1f}")
