# Phase 0 — Repo Map & Baseline

## Module graph & datapath guess

```
libellula_top
 ├─ aer_rx          (AER handshake → `ev_valid`)
 ├─ lif_tile_tmux   (time-mux LIF neurons, emits spikes + coords after 2 cycles)
 ├─ delay_lattice_rb (retinotopic delay buffers → multi-direction taps)
 ├─ reichardt_ds    (motion/direction correlation → signed dir_x/dir_y)
 ├─ burst_gate      (density/hysteresis gate for valid motion bursts)
 ├─ ab_predictor    (α-β predictor, produces `x_hat/y_hat` & `out_valid`)
 └─ conf_gate       (confidence score, not required for `pred_valid`)
```

`pred_valid` is ultimately driven by `ab_predictor.out_valid` which is asserted when `burst_gate` presents a valid candidate (`in_valid`) and the predictor is initialized.

## Event interface & timing conventions

* Clock: single `clk`, benches default to 100 MHz (10 ns) in provided TBs. Reset is synchronous active-high (`rst`).
* Input: AER-style handshake (`aer_req` level sensitive, `aer_ack` combinational). Event fields `aer_x/y/pol`.
* Internal scan: `lif_tile_tmux` requires external `scan_addr` to sweep neuron states (existing TBs just increment).
* Output: `pred_valid`, `x_hat`, `y_hat`, `conf`, `conf_valid`. No ready/ack; consumer must sample when `pred_valid=1`.

## Existing benches / entry points

* `sim/Makefile` orchestrates builds via Icarus (`iverilog` + `vvp`). Targets:
  * claim benches (`latency`, `px300`, `meps`, `power`)
  * scenario benches (e.g., `tb_cv_linear`, `tb_cross_clutter`)
  * hostile benches.
* Invocation example (already validated by repo):
  ```
  make -C sim build/tb_cv_linear
  vvp sim/build/tb_cv_linear
  ```
* Diagnostic harness (added earlier) resides under `benchmarks/` and uses `tb_benchmark_driver` + Python orchestration (`benchmarks/run_benchmarks.py`).

## Benchmark harness context

* Scenarios defined in `benchmarks/scenarios.py` (linear motion, abrupt acceleration, clutter, occlusion, noise, latency stress).
* Python runner synthesizes CSV events and drives `tb_benchmark_driver` via `iverilog`/`vvp`.
* Observed issue: all scenarios yielded `prediction_count=0` for `libellula_core` (no `pred_valid` ever asserted).

## Dataflow summary

1. External TB toggles `aer_req` with `(aer_x, aer_y, aer_pol)`.
2. `aer_rx` emits `ev_valid` + event coordinates in same cycle.
3. `lif_tile_tmux` integrates events per scanned neuron; when threshold reached (`spike`), outputs `out_valid` with coordinates of triggering event.
4. `delay_lattice_rb` consumes LIF spikes, feeds direction-specific ring buffers -> signals `v_e/v_w/...`.
5. `reichardt_ds` correlates taps, producing `ds_v` plus signed direction vectors.
6. `burst_gate` enforces density/hysteresis; outputs `bg_v` when motion energy sustained.
7. `ab_predictor` receives `bg_v`, updates α-β state, asserts `out_valid` (= `pred_valid`).

## Unknowns / ambiguities

* `scan_addr` requirements: documentation implies continuous sweep, but legal relationship to hashed `(x,y)` not fully specified.
* Minimum event density for `burst_gate`: thresholds in RTL (`TH_OPEN/TH_CLOSE`) but not explicitly documented for external harness.
* Delay lattice depth vs. event cadence: how long events must persist to produce correlation.
* Acceptable reset duration / warm-up before expecting emissions.
* Whether direction taps require alternating polarity stimuli (benchmarks using single polarity?).
* Relationship between scenario “cycle” and actual `scan_addr` progression (Python harness recently retimes events but still no emission).
* `conf_gate` not used: unclear if gating on `conf_valid` is expected downstream.

This completes Phase 0 without modifying RTL.
