"""EV-UAV .npz loader. Each file holds a structured array `ev` with fields
x, y (int16), t (float64, ms), p (0/1), label (0/1), name (target id, 0 = bg)
and `ev_loc` (x, y, integer-ms t) used by the reference evaluator."""
from __future__ import annotations

import glob
import os
from dataclasses import dataclass

import numpy as np


@dataclass
class Sequence:
    name: str
    x: np.ndarray      # int32
    y: np.ndarray      # int32
    t_us: np.ndarray   # int64 microseconds
    p: np.ndarray      # int8 (1 = ON / brighter, 0 = OFF / darker)
    label: np.ndarray  # int8
    ident: np.ndarray  # int16 target id
    t_ms: np.ndarray   # int64, ev_loc time used by the evaluator


def load(path: str) -> Sequence:
    d = np.load(path)
    ev = d["ev"]
    return Sequence(
        name=os.path.basename(path),
        x=ev["x"].astype(np.int32),
        y=ev["y"].astype(np.int32),
        t_us=np.round(ev["t"] * 1000.0).astype(np.int64),
        p=ev["p"].astype(np.int8),
        label=ev["label"].astype(np.int8),
        ident=ev["name"].astype(np.int16),
        t_ms=d["ev_loc"][:, 2].astype(np.int64),
    )


def load_dir(folder: str) -> list[Sequence]:
    return [load(f) for f in sorted(glob.glob(os.path.join(folder, "*.npz")))]
