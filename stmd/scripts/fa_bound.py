"""Upper bound on Fa under the released EV-UAV scorer: every distinct
background pixel in every 50 ms window counted as its own false cluster."""
import sys
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
import numpy as np
from libstmd import data
tot = frames = 0
for s in data.load_dir(sys.argv[1]):
    frames += int((s.t_ms.max() - s.t_ms.min()) / 50)
    bg = (s.label == 0) & ((s.t_ms % 50) != 0)
    tot += len(np.unique((s.t_ms[bg] // 50) * 1_000_000 + s.y[bg] * 1000 + s.x[bg]))
print(f"Fa upper bound = {tot / (frames * 346 * 260):.2e}")
