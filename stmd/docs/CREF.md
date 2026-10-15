# Fixed-point C reference (`cref/stmd_ref.c`), v27

Integer-only C99 implementation of the detector. It is the golden reference for RTL: the Verilog front end (`rtl/stmd_frontend.v`) and back end (`rtl/stmd_backend.v`) must match it bit for bit, and the Python model (`libstmd/model.py`) is the floating-point original it approximates.

## Number formats

| Quantity | Format | Notes |
|---|---|---|
| Event time | input int64 µs → 1 ms tick | C keeps full-width timestamps; ages saturate at 4095 ms (12 bits) and any stored entry older than 4095 ms reads as expired (decayed value 0, coincidence age 4095). The RTL stores 16-bit ms timestamps and relies on the same expiry rule plus an idle-cycle sweep that clears valid bits older than 4095 ms before the 16-bit counter can alias (every entry must be visited within ~60 s). `make -C sim stmd_sweep_neg` shows both replays fail without the sweeps. |
| Per-pixel timestamps (`last_any`, `last_pol[2]`, `flip_t`) | 16-bit ms + 1 valid bit each | 4 × 17 = 68 bits/px with ESTMD on; 2 × 17 = 34 without |
| Per-pixel flip count | Q12.4, 16 bits | plus 2-bit last polarity/valid |
| Cell accumulators (`R`, `A`), glare accumulators (`G`) | Q12.4, 16 bits + 16-bit ms reference time + valid | one event adds 16 (or 16 + w_estmd×16 for an ESTMD-correlated response) |
| Global rate accumulator (`Ng`) | Q12.4, 24 bits + 16-bit ms reference | |
| Decay | 128-entry Q16 table per time constant: `lut[k] = exp(-k·2^s/τ)`, `s = max(0, round(log2(τ/16)))` | index = (age >> s), a shift instead of the v26 division by the bucket width; the reference time advances by exactly `index << s`, so decay is exact at ms resolution and does not stall at high event rates. Age > 4095 ms or index ≥ 128 reads as 0 and resets the reference. |
| Weights `k_inh`, `k_act`, `w_estmd`, `theta`, `F_max` | Q4 | |
| `alpha`, `vel_beta`, `k_vlab` | Q8 | |
| Track position | Q8 px, int32 | |
| Track velocity | Q16 px/ms, int32 | measurement = (Δx_Q8 · 256) / Δt_ms, truncated toward zero; one integer division per velocity update (Δt ≥ `vel_dt_ms`, so at most every 50 ms per track). The RTL uses a 32-step restoring divider; this is the only division left in the pipeline. |
| Gates (`gate_px`, `D_min_px`, `D_stat_px`) | squared, Q16 px² | compared against integer squared distances |
| Noise adaptation | 64-entry tables indexed by `Ng >> rate_shift`, `rate_shift = round(log2((4 ev/px/s ÷ 64) × N_norm × 16))` | replaces the two per-event divisions of the Python model (`T_ba_eff`, `theta_eff`); table value = formula at the bucket centre. Rates above the last bucket clamp to it. |

Surround decision, all Q4: `rc·ns·16 − (k_inh·rs + k_act·as)·nc ≥ theta_eff·ns·16`, with `nc` centre cells (≤ 9) and `ns` ring cells (≤ 72). Needs 64-bit intermediates in C; the RTL uses 64-bit arithmetic for these and for the squared distances, which synthesis will narrow (the magnitudes fit in about 40 bits).

## Equivalence with the Python model

`scripts/c_equivalence.py` runs both on the same sequences and reports per-event agreement per stage and pooled metrics. On the v26 held-out set with the v25 configuration (`results/c_equivalence_holdout_v25cfg.txt`): activity filter 99.6 %, response 99.6 %, candidate 99.8 %, label 99.8 % agreement; IoU 0.760 vs 0.761; Pd, detection rate and false tracks per minute identical. Differences come from 1 ms ticks, bucketed decays and the rate tables, not from control flow. After the v27 changes (power-of-two decay buckets, expiry rule, shift-indexed rate tables) the agreement with the v26 segmentation configuration is 99.85 % of labels, IoU 0.762 vs 0.764, Pd 0.880 vs 0.888, false tracks 23.3 vs 20.6 per minute (`results/c_equivalence_holdout_v27.txt`).

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
- `stmd_ref --dump-tables CONFIG.txt DIR` writes the RTL parameter file `fe_params.vh` (every constant of both modules) and the decay and rate tables as `$readmemh` hex files; `tb/vectors/stmd_fe/` holds them for `configs/selected.json`.

`cref/cref.py` wraps this for Python (`cref.run(seq, cfg)` returns the same structure as `model.run`).

## Hardware budget

`scripts/hw_estimate.py` reports state memory and accesses per event for a configuration using these widths.
