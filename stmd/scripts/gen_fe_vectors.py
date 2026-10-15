"""T6: generate front-end test vectors for rtl/stmd_frontend.v from the C
reference on three synthetic scenes (no dataset needed):
  clean   one 5x5 dark target over sparse shot noise
  noisy   the same target over dense noise (1 ev/px/s)
  glare   the target plus a flickering 48x48 blob at ~6 ev/px/s
Each vector line is one 48-bit hex word:
  [47:40] expected bits (bit0 baf, bit1 habituated, bit2 glare)
  [39]    polarity   [38:23] t_ms   [22:12] y   [11:0] x
Also writes the C tables (fe_params.vh, *.hex) for the chosen config.
usage: gen_fe_vectors.py CONFIG.json OUT_DIR [N_EVENTS]   (clean: N, noisy and glare: 2N)"""
import os, sys, json, subprocess, tempfile
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import numpy as np
from cref import cref

W, H = 346, 260


def scene(kind, n_target_ms=2500, seed=1, bg_rate=0.1):
    rng = np.random.default_rng(seed)
    T = n_target_ms
    n_noise = int(bg_rate * W * H * T / 1000)
    ev = [np.stack([rng.integers(0, W, n_noise), rng.integers(0, H, n_noise),
                    rng.integers(0, T * 1000, n_noise), rng.integers(0, 2, n_noise)], 1)]
    x0, y0, v, size = 60.0, 120, 0.05, 5
    for t in range(T):
        lead = int(x0 + v * t) + size; trail = int(x0 + v * t)
        for col, pol in ((lead, 0), (trail, 1)):
            if rng.random() < 0.6:
                yy = y0 + rng.integers(0, size, 2)
                ev.append(np.stack([np.full(2, col), yy, t * 1000 + rng.integers(0, 1000, 2), np.full(2, pol)], 1))
    if kind == "glare":
        gx, gy, gs, rate = 250, 60, 32, 8.0
        n = int(rate * gs * gs * T / 1000)
        ev.append(np.stack([gx + rng.integers(0, gs, n), gy + rng.integers(0, gs, n),
                            rng.integers(0, T * 1000, n), rng.integers(0, 2, n)], 1))
    ev = np.concatenate(ev); ev = ev[np.argsort(ev[:, 2], kind="stable")]
    return ev


class Seq:  # minimal stand-in for data.Sequence
    def __init__(self, ev):
        self.x, self.y, self.t_us, self.p = ev[:, 0].astype(np.int32), ev[:, 1].astype(np.int32), ev[:, 2].astype(np.int64), ev[:, 3].astype(np.int8)


if __name__ == "__main__":
    cfg = json.load(open(sys.argv[1])); out = sys.argv[2]; nmax = int(sys.argv[3]) if len(sys.argv) > 3 else 12000
    os.makedirs(out, exist_ok=True)
    cref.build()
    with tempfile.TemporaryDirectory() as d:
        cfgp = os.path.join(d, "cfg.txt"); cref.write_config(cfg, cfgp)
        subprocess.check_call([cref.BIN, "--dump-tables", cfgp, out])
    for kind, rate, n in (("clean", 0.1, nmax), ("noisy", 1.0, 2 * nmax), ("glare", 0.1, 2 * nmax)):
        ev = scene(kind, bg_rate=rate)[:n]
        s = Seq(ev); r = cref.run(s, cfg, frontend=True); fe = r["frontend"] & 7
        t_ms = (s.t_us // 1000).astype(np.int64)
        word = (fe.astype(np.int64) << 40) | (s.p.astype(np.int64) << 39) | (t_ms << 23) | (s.y.astype(np.int64) << 12) | s.x.astype(np.int64)
        with open(os.path.join(out, f"fe_{kind}.hex"), "w") as fh:
            for w in word: fh.write(f"{w:012x}\n")
        print(f"{kind}: {len(ev)} events, baf {((fe&1)>0).mean():.3f} hab {((fe&2)>0).mean():.3f} glare {((fe&4)>0).mean():.3f}")
