# 11 — Repair and End-to-End Validation

**Status: PASS — pipeline tracking confirmed, ±2px accuracy achieved in steady state**

---

## Fixes Applied

| File | Change | Rationale |
|---|---|---|
| `rtl/lif_tile_tmux.v` | `LEAK_SHIFT` 2 → 4 | Fixed point rises to 2^4=16=THRESH; neuron can spike |
| `rtl/lif_tile_tmux.v` | XOR hash → tile hash `{x[9:6],y[9:6]}` | Spatial locality: nearby pixels map to nearby neurons |
| `rtl/lif_tile_tmux.v` | Added `out_ex`, `out_ey` outputs | Exact triggering-event pixel coords for sub-tile predictor accuracy |
| `rtl/lif_tile_tmux.v` | Spike output coords → tile-snapped `{scan_addr_s1[7:4], scan_addr_s1[3:0]}` | Delay lattice sees coords that differ by exactly 1 per adjacent neuron |
| `rtl/delay_lattice_rb.v` | Added `STEP` parameter (default=1) | Neighbor detection parameterised for tile granularity |
| `rtl/libellula_top.v` | Added `TILE_STEP=64` localparam, passed to delay lattice | Connects tile hash with direction detection |
| `rtl/libellula_top.v` | `burst_gate` WINDOW 16→1024, TH_OPEN 3→2 | Window must span multiple scan periods (~256 cycles each) |
| `rtl/libellula_top.v` | Added `ex_d1/d2/d3`, `ey_d1/d2/d3` pipeline registers | Route exact event coords to predictor with correct latency alignment |
| `rtl/libellula_top.v` | Predictor input: `ex_d3`/`ey_d3` instead of `x_t_d2`/`y_t_d2` | Sub-tile pixel accuracy for position tracking |

---

## Bench Results

### tb_e2e_motion (scan-synchronised, 10-tile trajectory)
```
E2E_RESULT status=PASS ev=200 lif=10 ds=10 burst=9 pred=9
E2E_FIRST  first_lif=3882 first_ds=3884 first_burst=9277 first_pred=9278
```
All pipeline stages active. `pred_valid` asserted 9 times.

### tb_accuracy (prediction error measurement)
```
ACC_RESULT status=PASS preds=11 ev=240 lif=12 ds=12 burst=11
ACC_ERROR  mean_x=5.9 max_x=16  mean_y=0.0 max_y=0  (pixels)
```
Convergence profile:

| Update # | err_x | err_y |
|---|---|---|
| 1  | 0px  | 0px |
| 2  | 16px | 0px |
| 3  | 16px | 0px |
| 4  | 12px | 0px |
| 5  | 8px  | 0px |
| 6  | 5px  | 0px |
| 7  | 3px  | 0px |
| **8**  | **2px**  | **0px** |
| 9–11 | **1px**  | **0px** |

**±2px claim confirmed in steady state (8+ updates after cold start).**  
Peak error 16px is cold-start lag (velocity unknown at first measurement).

### tb_naturalistic (continuous unsynchronised injection)
```
NAT_RESULT status=PASS ev_cyc=60000 lif=10 ds=10 burst=9 pred=9 first_pred=10558
PASS: naturalistic continuous injection works — pred_valid fired 9 times
```
Pipeline tracks correctly with persistent (non-scan-synchronised) event generation.

---

## Architecture Notes

### Dual-output LIF design
- `out_x`/`out_y`: tile index in each dimension (0–15 for AW=8). Used by `delay_lattice_rb` for direction detection. Adjacent-tile spikes differ by exactly 1, making STEP=64 correlation work.
- `out_ex`/`out_ey`: actual triggering-event pixel coordinates. Passed directly to `ab_predictor` with correct pipeline delay. Gives sub-tile position accuracy — the Q8.8 alpha-beta filter can interpolate within a 64×64 tile region.

### Why ±2px is achievable with tile-granularity LIF
The alpha-beta filter has Q8.8 internal precision (0.004px resolution). Each measurement gives the exact pixel position of the event that triggered the threshold crossing (from `out_ex`/`out_ey`). After velocity warm-up (~7 updates), the filter's prediction is accurate to 1–2px because:
- Measurement noise = jitter within the 64px tile (up to ±32px)
- Filter α=0.75 heavily weights recent measurements
- Velocity estimate β=0.25 converges to correct tile-step rate
- Residual = (predicted − measured) converges toward 0

### Scan timing for naturalistic input
With AW=8, the scan visits each of 256 addresses once per 256-cycle period. A continuously-asserted event gets exactly 1 scan hit per period. With THRESH=16, LIF spikes after 16 scan periods = 4096 cycles. At 200 MHz real silicon clock, that is 20.5μs — well within a 300 Hz (3.33 ms) frame budget.

---

## Remaining Limitations

1. **AW=8 → 64×64px tile granularity.** The ±2px steady-state accuracy comes from exact event coords, not tile resolution. Performance is bounded by how tightly the event cluster is localised within its tile — a diffuse blob would reduce effective accuracy.

2. **Cold-start lag = 16px** (first 2–3 updates). This is intrinsic to the α-β filter's velocity warm-up. Pre-loading velocity from a prior track would eliminate it.

3. **Naturalistic model = continuous flood.** Real DVS events are sparse in time. With sparse events and no scan synchronisation, hit rate per scan period can fall below 1 → LIF doesn't accumulate. Solution: reduce AW (shorter scan period) or increase burst gate tolerance.

4. **Single-target only.** Multi-target isolation, clutter rejection, and target handoff are unvalidated.

5. **±2px in pixel coords, not in angle.** No mapping to angular space (optics-dependent).

---

## Recommended Next Steps

1. Multi-target bench: two targets, verify predictor locks to the correct one
2. Clutter injection: add background noise events, verify burst gate rejects them
3. Target crossing: two targets on intersecting paths — tests tracker identity
4. AW sweep: characterise accuracy vs. AW (trade scan period vs. spatial resolution)
5. Direction reversal: target stops and reverses — tests predictor recovery time
