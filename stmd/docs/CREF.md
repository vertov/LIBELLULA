# Fixed-point C reference (`cref/stmd_ref.c`), v26

Integer-only C99 implementation of the detector. It is the golden reference for RTL: the Verilog front end (`rtl/stmd_frontend.v`) must match it bit for bit, and the Python model (`libstmd/model.py`) is the floating-point original it approximates.

## Number formats

| Quantity | Format | Notes |
|---|---|---|
| Event time | input int64 µs → 16-bit ms tick | wraps at 65.5 s; ages saturate at 4095 ms (12 bits). Sequences here are 8 s. A deployment needs a periodic sweep that invalidates stale entries, as LIBELLULA's LIF scan does. |
| Per-pixel timestamps (`last_any`, `last_pol[2]`, `flip_t`) | 16-bit ms + 1 valid bit each | 4 × 17 = 68 bits/px with ESTMD on; 2 × 17 = 34 without |
| Per-pixel flip count | Q12.4, 16 bits | plus 2-bit last polarity/valid |
| Cell accumulators (`R`, `A`), glare accumulators (`G`) | Q12.4, 16 bits + 16-bit ms reference time + valid | one event adds 16 (or 16 + w_estmd×16 for an ESTMD-correlated response) |
| Global rate accumulator (`Ng`) | Q12.4, 24 bits + 16-bit ms reference | |
| Decay | 128-entry Q16 table per time constant: `lut[k] = exp(-k·b/τ)`, `b = max(1, round(τ/16)) ms` | index = whole buckets elapsed since the reference time; the reference advances by exactly the buckets applied, so decay is exact at ms resolution and does not stall at high event rates |
| Weights `k_inh`, `k_act`, `w_estmd`, `theta`, `F_max` | Q4 | |
| `alpha`, `vel_beta`, `k_vlab` | Q8 | |
| Track position | Q8 px, int32 | |
| Track velocity | Q16 px/ms, int32 | measurement = (Δx_Q8 · 256) / Δt_ms, one integer division per velocity update (Δt ≥ `vel_dt_ms`) |
| Gates (`gate_px`, `D_min_px`, `D_stat_px`) | squared, Q16 px² | compared against integer squared distances |
| Noise adaptation | 64-entry tables indexed by `Ng / step`, `step` = (4 ev/px/s ÷ 64) × N_norm × 16 | replaces the two per-event divisions of the Python model (`T_ba_eff`, `theta_eff`); table value = formula at the bucket centre. Rates above 4 ev/px/s clamp to the last bucket. |

Surround decision, all Q4: `rc·ns·16 − (k_inh·rs + k_act·as)·nc ≥ theta_eff·ns·16`, with `nc` centre cells (≤ 9) and `ns` ring cells (≤ 72). Needs 64-bit intermediates in C; an RTL implementation should use ≈ 40 bits.

## Equivalence with the Python model

`scripts/c_equivalence.py` runs both on the same sequences and reports per-event agreement per stage and pooled metrics. On the v26 held-out set with the v25 configuration (`results/c_equivalence_holdout_v25cfg.txt`): activity filter 99.6 %, response 99.6 %, candidate 99.8 %, label 99.8 % agreement; IoU 0.760 vs 0.761; Pd, detection rate and false tracks per minute identical. Differences come from 1 ms ticks, bucketed decays and the rate tables, not from control flow.

Two bugs found by this test during development: the lazy decay stalled when consecutive events fell in the same ms (fixed by the telescoping reference time), and the glare mute was missing from the labelling stage.

## Interfaces

```
cc -O2 -std=c99 -o cref/stmd_ref cref/stmd_ref.c -lm
cref/stmd_ref CONFIG.txt EVENTS.bin LABELS.bin TRACKS.txt [FRONTEND.bin]
```

- `CONFIG.txt`: `key=value` per line, the same keys as `configs/*.json` (`cref/cref.py` writes it).
- `EVENTS.bin`: 24-byte records, little-endian: int32 x, int32 y, int64 t_us, int8 p, 3 pad bytes.
- `LABELS.bin`: one byte per event, 1 = target.
- `TRACKS.txt`: `t_us uid x_q8 y_q8 vx_q16 vy_q16` per update of a confirmed moving track.
- `FRONTEND.bin`: one byte per event; bit0 baf, bit1 habituated, bit2 glare, bit3 response, bit4 candidate. Used by the RTL benches.

`cref/cref.py` wraps this for Python (`cref.run(seq, cfg)` returns the same structure as `model.run`).

## Hardware budget

`scripts/hw_estimate.py` reports state memory and accesses per event for a configuration using these widths.
