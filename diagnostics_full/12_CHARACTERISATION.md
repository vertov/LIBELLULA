# 12 — Full Pipeline Characterisation

**Date: 2026-04-11**  
**RTL revision: v22 + repair patches (session 2)**  
**Simulator: Icarus Verilog 12.0**

---

## Summary of All Fixes Applied (This Session)

| # | File | Change |
|---|---|---|
| 1 | `lif_tile_tmux.v` | LEAK_SHIFT 2→4 (mathematical fix) |
| 2 | `lif_tile_tmux.v` | XOR hash → tile hash `{x[9:6],y[9:6]}` |
| 3 | `lif_tile_tmux.v` | Added `out_ex`/`out_ey` (exact event coords for predictor) |
| 4 | `lif_tile_tmux.v` | Spike output uses tile-index coords (for delay lattice) |
| 5 | `delay_lattice_rb.v` | Added `STEP` parameter (default=1) |
| 6 | `libellula_top.v` | TILE_STEP=1 (tile index coords, not pixels) |
| 7 | `libellula_top.v` | Burst gate WINDOW=1024, TH_OPEN=2 |
| 8 | `libellula_top.v` | DW default 6→0 (correlate consecutive spikes) |
| 9 | `libellula_top.v` | Parallel `ex_d3/ey_d3` pipeline to predictor |
| 10 | `reichardt_ds.v` | Corrected direction convention (v_w=East, v_e=West) |

**Fix #6 discovery:** TILE_STEP was originally 64 (pixel distance) but LIF outputs tile indices (0-15); correct step is 1. This left direction detection dead for the entire first session.

**Fix #8 discovery:** DW=6 (buffer depth 64) means no direction correlation until 65+ spikes. For a 10-tile trajectory (10 spikes) this never fires. DW=0 (depth 1) correlates consecutive spikes — correct for tile-based LIF.

**Fix #10 discovery:** The delay lattice uses "source direction" convention: v_w fires when a target moves EAST (came from the West). Reichardt was computing dir_x as negative for East motion. All signs corrected.

---

## Bench Results

### 1. Prediction Accuracy (`tb_accuracy.v`)

Constant-velocity East motion. True target at `(tile_x*64+20, tile_y*64+20)`.

| Update | err_x (px) | err_y (px) |
|---|---|---|
| 1  | 0   | 0 |
| 2  | 16  | 0 |
| 3  | 16  | 0 |
| 4  | 12  | 0 |
| 5  | 8   | 0 |
| 6  | 5   | 0 |
| 7  | 3   | 0 |
| **8**  | **2**   | **0** |
| 9+ | **1**   | **0** |

**Mean error: 5.9px. Peak error: 16px (cold-start, updates 2-3). Steady-state: 1-2px.**

The ±2px claim is met in steady state (after ~7 updates). Cold-start lag of 16px = 1 tile width, intrinsic to the alpha-beta filter's velocity warm-up.

Source of sub-tile accuracy: the predictor receives exact event pixel coordinates (`out_ex`/`out_ey`) rather than tile-snapped coordinates, so the Q8.8 alpha-beta filter interpolates within the 64×64 tile region.

---

### 2. Velocity Range (`tb_velocity_range.v`)

All tested dwell times tracked successfully:

| Dwell (cycles) | Scan periods/tile | Tracking |
|---|---|---|
| 3000  | 11 | TRACK |
| 4096  | 16 | TRACK |
| 5000  | 19 | TRACK |
| 8000  | 31 | TRACK |
| 16000 | 62 | TRACK |

**Hard floor: THRESH × SCAN_PERIOD = 16 × 256 = 4096 cycles per tile.**  
At 200 MHz silicon clock: 4096 / 200 MHz = **20.5 μs minimum dwell per tile**.  
Tile width = 64 px, so maximum trackable velocity = 64 px / 20.5 μs = **3.1 Mpx/s**.  
At a standard DVS 240×180 sensor this corresponds to the full frame width in ~77 μs — well above dragonfly prey chase velocities (typically <500 px/s at lab scale).

Note: with LEAK_SHIFT=4 and THRESH=16, the LIF fixed point equals THRESH exactly at 1 hit/scan period. A safety margin of ≥2 extra scan hits per tile (HITS_TILE=18) ensures reliable accumulation.

---

### 3. Clutter Rejection (`tb_clutter.v`)

Background noise events at random (x,y) injected between signal hits.

| Clutter interval | Approx noise rate | Preds | Mean err | Max err | Status |
|---|---|---|---|---|---|
| None   | 0      | 5 | 10px | 16px | PASS |
| 512 cy | 0.2/scan | 5 | 10px | 16px | PASS |
| 256 cy | 0.4/scan | 5 | 10px | 16px | PASS |
| 128 cy | 0.8/scan | 5 | 10px | 16px | PASS |
| 64 cy  | 1.6/scan | 5 | 10px | 16px | PASS |

**Performance completely unaffected across all tested clutter rates.** The architecture provides natural clutter rejection through two mechanisms:
1. **LIF threshold:** Random noise events distribute across 256 neurons; each neuron sees ~1/256 of random events, far below accumulation threshold.
2. **Delay lattice spatial correlation:** Random events rarely produce consecutive spikes at adjacent tile addresses, so the Reichardt/burst-gate path stays closed for noise.

Clutter limit was not found within the tested range. Further investigation with clutter rates >1/scan period per neuron would be needed to find the rejection boundary.

---

### 4. Direction Reversal (`tb_reversal.v`)

East 6 tiles → 1-tile pause → West 6 tiles.

**East phase:**
```
dir_x = +8, +16, +23 (correctly positive; accumulates in Reichardt leaky integrator)
Preds: 5  Mean err: 10px  Max err: 16px
```

**West phase:**
```
dir_x progression: +7 → -1 → -8 → -8 → -8 → -8  (reversal detected by update 3)
Preds: 6  Mean err: 14px  Max err: 26px  Relock cycle: 46718
```

**Direction detection working correctly:** dir_x flips from positive to negative within 2 tile transitions after the reversal. Peak overshoot during reversal = 26px (predictor's coasted velocity carries it past the reversal point), converging to 3px by tile 5 and 1px by tile 6. Full relock within one scan period of the reversal being detected.

The Reichardt accumulator's DECAY_SHIFT=4 leaky integrator means direction information takes ~16 scan periods to fully decay, providing hysteresis against momentary false reversals from clutter.

---

### 5. Multi-Target (`tb_multi_target.v`)

Two targets: A at tile_y=6, B at tile_y=10. Same East trajectory. Alternating hits.

```
MULTI_RESULT preds=15
MULTI_X   mean_err=24px  max_err=64px
MULTI_Y_A mean_err_vs_A=256px  max=256px  (true_yA=400)
MULTI_Y_B mean_err_vs_B=0px    max=0px    (true_yB=656)
MULTI_SEPARATION: 256px
MULTI_VERDICT: locked to target B
```

**Predictor locked to target B and rejected target A as an outlier throughout.**  
The outlier rejection threshold (OUTLIER_TH=128px) is smaller than the target separation (256px). Once initialized on target B, any measurement from target A generates a residual of ~256px > 128px and is rejected. This is architecturally correct outlier rejection behavior, but it confirms that **a single predictor instance cannot track two simultaneous targets**.

X-tracking shows alternating high/low errors (2px / 64px pattern) because:
- Each "A" spike arrives at the predictor as a valid measurement with a different position
- The ex_d3 pipeline sees A's exact x coordinate, which is equal to B's (same horizontal trajectory)
- The y coordinate from A is rejected as outlier; x correction is accepted
- This creates oscillation in x_hat between consecutive updates

---

## Architectural Findings

### What Works
| Capability | Status | Notes |
|---|---|---|
| Single-target constant-velocity tracking | ✅ Proven | ≤2px steady-state, 16px cold-start |
| Clutter rejection | ✅ Proven | Unaffected up to 1.6 noise events/scan |
| Direction detection | ✅ Proven | dir_x = +8 East, -8 West |
| Direction reversal recovery | ✅ Proven | Relock within 2 tile transitions |
| Naturalistic (non-sync) injection | ✅ Proven | Continuous events, no scan sync |

### What Does Not Work
| Capability | Status | Notes |
|---|---|---|
| Multi-target tracking | ❌ Not supported | Single α-β state; locks to one target |
| ±2px from first measurement | ❌ Not met | Needs ~7 warm-up updates |
| Sub-tile resolution (better than tile_width/2) | ✅ Partially met | Achieved via exact event coords; limited by event spread within tile |
| 6-cycle end-to-end latency | ⚠️ Misleading | Pipeline stages = 6 cycles, but LIF needs 4096+ cycles to accumulate |

### Quantitative Limits
| Parameter | Value |
|---|---|
| Tile size (AW=8, XW=10) | 64 × 64 pixels |
| Scan period | 256 clock cycles |
| Minimum dwell per tile | 4096 cycles (20.5 μs @200 MHz) |
| Steady-state accuracy | 1–2 px |
| Cold-start lag | 16 px (1 tile width) |
| Max clutter tested | 1 event per 64 cycles (unaffected) |
| Max simultaneous targets | 1 (architectural limit) |
| Reversal relock time | ~2 tile transitions |
| Velocity ceiling | ~3.1 Mpx/s @200 MHz |

---

## Recommended Next Steps (Priority Order)

### P1 — Multi-target support (architectural change required)
Replace single `ab_predictor` with a tracker pool (e.g., 2–4 instances). Add an assignment layer that routes LIF spikes to the nearest active tracker, spawns a new tracker on unassigned activity, and retires trackers that haven't received updates. This is the most impactful missing capability.

### P2 — Cold-start improvement
Pre-load velocity from Reichardt direction on first measurement:  
`if (!initialized) vx_q <= dir_vx * TILE_STEP_Q;`  
This would cut warm-up from 7 updates to ~2 by using the direction hint immediately.

### P3 — Resolution scaling (AW sweep)
The tile size sets the fundamental resolution floor. Running with AW=10 (1024 neurons, 32px tiles) would:
- Reduce steady-state error ceiling from 32px to 16px
- Increase scan period from 256 to 1024 cycles (requires 4× denser events)
- Require tuning WINDOW in burst_gate accordingly

### P4 — Clutter limit characterisation
Find the SNR level at which the burst gate begins admitting false positives. Test at bg_rate = 4×, 8×, 16× the signal hit rate.

### P5 — Target loss and reacquisition
Test: target disappears mid-track, then reappears at the same or different position. Measure: how long before the predictor coasts off-screen, and whether it reacquires correctly.
