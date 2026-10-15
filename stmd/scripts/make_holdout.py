"""T1: deterministic, stratified held-out split of 20 train sequences.
Strata from the raw data only (no model): background event rate and
persistently hot 8x8-px cells (glare proxy). Picks 3 glare, 3 dense-noise,
14 ordinary with a fixed seed. usage: make_holdout.py TRAIN_DIR OUT.txt"""
import os, sys, glob, random
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import numpy as np
from libstmd import data
rows = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.npz"))):
    s = data.load(f); g = s.label > 0
    dur = (s.t_us.max() - s.t_us.min()) / 1e6
    rate = (~g).sum() / dur / 346 / 260
    cnt = np.zeros((33, 44)); np.add.at(cnt, (s.y[~g] // 8, s.x[~g] // 8), 1)
    hot = int((cnt > 20 * np.median(cnt[cnt > 0])).sum())
    rows.append((s.name, rate, hot))
glare = sorted([r for r in rows if r[2] >= 10], key=lambda r: -r[2])
noise = sorted([r for r in rows if r[1] >= 0.5 and r[2] < 10], key=lambda r: -r[1])
rest = [r for r in rows if r not in glare and r not in noise]
rng = random.Random(26)
pick = rng.sample(glare, 3) + rng.sample(noise, 3) + rng.sample(rest, 14)
names = sorted(r[0] for r in pick)
with open(sys.argv[2], "w") as fh:
    fh.write("# v26 held-out split: 20 train sequences, seed 26, stratified\n")
    fh.write(f"# strata: glare (>=10 hot cells) {len(glare)} available, 3 picked; dense noise (>=0.5 ev/px/s) {len(noise)} available, 3 picked; ordinary {len(rest)} available, 14 picked\n")
    for n in names:
        r = next(x for x in rows if x[0] == n)
        tag = "glare" if r in glare else "noise" if r in noise else "ordinary"
        fh.write(f"{n}\t# {tag}, bg {r[1]:.2f} ev/px/s, hot cells {r[2]}\n")
print(open(sys.argv[2]).read())
