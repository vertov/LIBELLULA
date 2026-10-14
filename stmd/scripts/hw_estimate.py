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

TS = 12  # bits per timestamp: 1 ms resolution, saturating age up to 4.1 s
px_bits = TS                      # last event (BAF)
if P.use_estmd:
    px_bits += 2 * TS             # last ON, last OFF
if P.use_habituation:
    px_bits += TS + 4 + 1         # flip-count timestamp, 4-bit leaky count, last polarity
cells = ((H + P.cell - 1) // P.cell) * ((W + P.cell - 1) // P.cell)
cell_bits = (2 if P.use_surround and P.k_act > 0 else 1) * (16 + TS)
mem_kB = (W * H * px_bits + cells * cell_bits) / 8 / 1024

nb = (2 * P.nb_radius + 1) ** 2 if P.use_estmd else 0
ring = (2 * (P.surround_r if P.use_surround else 1) + 1) ** 2
acc_per_event = (
    8 + 1                                 # BAF neighbour reads + write
    + (2 if P.use_habituation else 0)     # flip state read/write
    + (baf / n) * (nb + 1 + 2)            # ESTMD reads, polarity write, activity cell update
    + (resp / n) * (ring * (2 if P.k_act > 0 else 1) + 2)   # centre-surround reads
    + (cand / n) * 2 * P.n_tracks         # track gating
    + P.n_tracks                          # labelling test
)
print(json.dumps({
    "per_pixel_bits": px_bits,
    "cells": cells,
    "state_memory_kB": round(mem_kB, 1),
    "events": int(n), "mean_event_rate_ev_per_s": round(n / dur_s),
    "peak_sequence_rate_ev_per_s": round(peak),
    "pass_rates": {"baf": round(baf / n, 3), "response": round(resp / n, 3), "candidate": round(cand / n, 4)},
    "mean_state_accesses_per_event": round(acc_per_event, 1),
    "accesses_per_response_event": ring * (2 if P.k_act > 0 else 1) + 2,
}, indent=1))
