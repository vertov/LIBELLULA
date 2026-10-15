"""Rough hardware budget for a frozen configuration: state memory and memory
accesses per event, using measured stage pass rates on a data split.
usage: hw_estimate.py CONFIG.json DATA_DIR"""
import sys, json
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
import numpy as np
from libstmd import data, model

W, H = 346, 260
cfg = json.load(open(sys.argv[1]))
P = model.Params(**cfg)
seqs = data.load_dir(sys.argv[2])

n = baf = resp = cand = 0
dur_s = 0.0
peak = 0.0
for s in seqs:
    o = model.run(s, P)
    n += len(s.x); baf += o["baf"].sum(); resp += o["resp"].sum(); cand += o["cand"].sum()
    d = (s.t_us.max() - s.t_us.min()) / 1e6
    dur_s += d
    peak = max(peak, len(s.x) / d)

# Widths follow the C reference (docs/CREF.md): 16-bit ms timestamps + valid bit,
# Q12.4 16-bit accumulators.
TS = 17  # 16-bit ms timestamp + 1 valid bit
px_bits = TS                      # last event (BAF)
if P.use_estmd:
    px_bits += 2 * TS             # last ON, last OFF
if P.use_habituation:
    px_bits += TS + 16 + 2        # flip reference time, Q12.4 flip count, last polarity + valid
cells = ((H + P.cell - 1) // P.cell) * ((W + P.cell - 1) // P.cell)
cell_bits = (2 if P.use_surround and P.k_act > 0 else 1) * (16 + TS)
g_cells = ((H + P.g_cell - 1) // P.g_cell) * ((W + P.g_cell - 1) // P.g_cell) if P.use_glare else 0
coarse_cells = ((((H + P.cell - 1) // P.cell) + P.sur_k - 1) // P.sur_k) * ((((W + P.cell - 1) // P.cell) + P.sur_k - 1) // P.sur_k) if (P.use_surround and getattr(P, "sur_mode", 0) == 1) else 0
mem_kB = (W * H * px_bits + cells * cell_bits + coarse_cells * 2 * (16 + TS) + g_cells * (16 + TS)) / 8 / 1024

nb = (2 * P.nb_radius + 1) ** 2 if P.use_estmd else 0
ring = (2 * (P.surround_r if P.use_surround else 1) + 1) ** 2
coarse = P.use_surround and getattr(P, "sur_mode", 0) == 1
acc_per_event = (
    8 + 1                                 # BAF neighbour reads + write
    + (2 if P.use_glare else 0)           # glare cell read/write
    + (2 if P.use_habituation else 0)     # flip state read/write
    + (baf / n) * (nb + 1 + 2)            # ESTMD reads, polarity write, activity cell update
    + (resp / n) * ((9 * 2 + 9 * 2 + 2 + 2) if coarse else (ring * (2 if P.k_act > 0 else 1) + 2))   # centre-surround reads
    + (cand / n) * 2 * P.n_tracks         # track gating
    + P.n_tracks                          # labelling test
)
print(json.dumps({
    "per_pixel_bits": px_bits,
    "cells": cells,
    "glare_cells": g_cells,
    "state_memory_kB": round(mem_kB, 1),
    "events": int(n), "mean_event_rate_ev_per_s": round(n / dur_s),
    "peak_sequence_rate_ev_per_s": round(peak),
    "pass_rates": {"baf": round(baf / n, 3), "response": round(resp / n, 3), "candidate": round(cand / n, 4)},
    "mean_state_accesses_per_event": round(acc_per_event, 1),
    "accesses_per_response_event": (9 * 2 + 9 * 2 + 2 + 2) if coarse else ring * (2 if P.k_act > 0 else 1) + 2,
    "surround": "coarse 3x3 grid (k=%d)" % P.sur_k if coarse else "ring r=%d" % P.surround_r,
}, indent=1))
