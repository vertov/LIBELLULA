"""Python wrapper for the fixed-point C reference (cref/stmd_ref.c).
run(seq, cfg) -> dict with pred (bool array), tracks (dict of arrays, Q8/Q16
converted to float px and px/ms) and frontend bits."""
import os, json, subprocess, tempfile
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "stmd_ref")
SRC = os.path.join(HERE, "stmd_ref.c")
EVENT_DT = np.dtype([("x", "<i4"), ("y", "<i4"), ("t_us", "<i8"), ("p", "i1"), ("pad", "i1", 3)], align=True)  # 24 bytes, matches the C struct


def build():
    if not os.path.exists(BIN) or os.path.getmtime(BIN) < os.path.getmtime(SRC):
        subprocess.check_call(["cc", "-O2", "-std=c99", "-o", BIN, SRC, "-lm"])


def write_config(cfg: dict, path: str):
    with open(path, "w") as fh:
        for k, v in cfg.items():
            fh.write(f"{k}={float(v)}\n")


def write_events(x, y, t_us, p, path):
    ev = np.zeros(len(x), EVENT_DT)
    ev["x"] = x; ev["y"] = y; ev["t_us"] = t_us; ev["p"] = p
    ev.tofile(path)


def run(seq, cfg: dict, frontend: bool = False, workdir: str = None) -> dict:
    build()
    with tempfile.TemporaryDirectory(dir=workdir) as d:
        cfgp, evp, labp, trkp, fep = (os.path.join(d, n) for n in ("cfg.txt", "ev.bin", "lab.bin", "trk.txt", "fe.bin"))
        write_config(cfg, cfgp); write_events(seq.x, seq.y, seq.t_us, seq.p, evp)
        args = [BIN, cfgp, evp, labp, trkp] + ([fep] if frontend else [])
        subprocess.check_call(args)
        pred = np.fromfile(labp, np.uint8).astype(bool)
        tr = np.loadtxt(trkp, dtype=np.int64, ndmin=2) if os.path.getsize(trkp) else np.zeros((0, 6), np.int64)
        out = {"pred": pred, "tracks": {"t_us": tr[:, 0], "uid": tr[:, 1], "x": tr[:, 2] / 256.0, "y": tr[:, 3] / 256.0,
                                        "vx": tr[:, 4] / 65536.0, "vy": tr[:, 5] / 65536.0}}
        if frontend:
            out["frontend"] = np.fromfile(fep, np.uint8)
        return out
