# Changelog

## v24 — 2026-10-14

Adds `stmd/`, a Python reference model for event-driven small-target detection, evaluated on real event-camera data. **RTL behaviour is unchanged from v22**; the edits outside `stmd/` are this entry, a README section, one CI step and version labels.

- **Model** (`stmd/libstmd/model.py`). Causal, per-event pipeline: background-activity filter → flicker habituation → optional ESTMD polarity correlation → centre-surround inhibition (responses and raw activity) → tracker pool with α-β update and a stationarity check → event labelling.
- **Evaluation** (`stmd/libstmd/metrics.py`). Port of the EV-UAV authors' evaluator (IoU, ACC, Pd, Fa), matched against a line-by-line transcription of their code (`stmd/scripts/check_metrics.py`).
- **Protocol.**
  - 33 parameters tuned by random search on EV-UAV `val` only: about 1,150 configurations for the full model, plus 150 per ablation.
  - The selected variant (no ESTMD stage) was chosen on `val`.
  - `test` was scored once.
- **Results on EV-UAV test.**
  - This model: IoU 0.667, recall 0.845, Pd 0.883.
  - Published EV-SpSegNet: 0.552, 0.650, 0.775.
  - 95 % bootstrap intervals over sequences are in `stmd/results/`.
  - The paper's Fa column is not reproducible with the released scorer: 9 of its 14 values exceed the scorer's maximum on this test set (`stmd/scripts/fa_bound.py`).
- **Ablations.**
  - Centre-surround inhibition and the tracker carry the result.
  - The ESTMD polarity correlation gives no measurable gain.
- **Known failures.**
  - Sun glare (test_008): 79 % of all test false positives sit in 14 persistently hot cells.
  - Dense sensor noise (test_022, test_023): target-to-noise event ratio about 5:1, against 12–40:1 in clean scenes.
- **CI** runs a data-free synthetic smoke test of the model (`stmd/tests/smoke.py`).
- EV-UAV data is not included.

## v23 — 2026-10-14

Claims and verification-harness corrections. **RTL behaviour is unchanged from v22**: the only edits under `rtl/` are comments and version headers.

### Comparative benchmark (`benchmarks/`)
- `tb_benchmark_driver.v` paired prediction *k* with input event *k* through a FIFO. The core emits far fewer predictions than events under default parameters, so every prediction after the first was scored against the wrong ground truth. The v22 report showed 82–214 px MAE and 100 % false lock for the core; the corrected figures are 2.4–6.1 px MAE on five of six scenes and 34 px on `distractor_crossings`. Predictions are now paired with the newest event presented at least one pipeline depth earlier.
- `tiny_learned` baseline replaced with a normalised-LMS velocity regressor; the v22 version diverged to NaN.
- `benchmark_report.md` now lists every tracker per scenario, states that baseline latencies are nominal constants, and that all stimulus is synthetic.
- Result: the software baselines are more accurate on clean scenes (0.5–1 px vs 2.4–4.5 px); the core is ahead of the Kalman and event-motion baselines on the distractor and noise-burst scenes.

### ±2 px accuracy claim
- `tb_px_bound_300hz.v` replaced by `tb_px_bound.v`; make target `px300` replaced by `pxbound`.
- The v22 bench spaced events 667 cycles apart at 200 MHz (3.3 µs, ~300 k events/s) and called it 300 Hz. The same mislabel is corrected in `tb_sparse_events`, `tb_prediction_error`, RTL comments and `tools/req_trace.py`.
- The v22 bench scored predictions against the current event position, which a core that echoed its input would also pass. `tb_px_bound` scores against the next position and also requires mean error below the echo baseline. Result at 1 px/event: mean 0.73 px, max 2 px.
- The bench now drives single-cycle REQ pulses; the v22 two-cycle REQ injected each event twice into the level-sensitive `aer_rx`.
- `make pxbound-char` records configurations outside the claim: at 2–3 px/event the bound is exceeded (max 3–4 px); at 300 events/s the error stays within ±2 px but is no better than echo.

### Latency claim
- `tb_latency` now fails above 5 cycles (v22 failed only above 12).
- New `tb_latency_default` (`make latency-default`): under default parameters every emitted prediction is 5 cycles after its event, the first prediction follows 32 events, and the core emits one prediction per ~17 events for a single slow target.
- README and Engineering Overview no longer state the 5-cycle figure as if every event produced a prediction.

### CI and lint
- Workflow runs with `shell: bash` (pipefail). Under GitHub's default shell, `make … | tee` reported tee's status, so a failing `make lint` (and any compile error) passed CI.
- `-Wno-PROCASSINIT` is applied only when the installed Verilator supports it. Verilator 5.020 (Ubuntu 24.04, used by CI) rejects the flag; lint is clean on 5.020.
- CI also runs `latency-default` and the benchmark harness (results not gated).

### Housekeeping
- `tb_clutter` and `tb_velocity_range` wired to `make clutter-sweep`, `make velocity-sweep` and `make characterize`; `tb_debug` (no checks) removed.
- Bench counts corrected: 38 core benches (4 claim, 10 unit, 21 scenario, 3 hostile).
- Documentation corrected for `LIF_SCAN_MODE=1` (default; `scan_addr` ignored), the level-sensitive `aer_rx` (not a 4-phase receiver), the 1 Meps bench (ACK=REQ holds by construction; PRED=2000 in latency mode, not 7), and the 16 px reversal overshoot (not 26 px).
- New limitations recorded in ENGINEERING_OVERVIEW §9 (items 11–13).

### Unchanged
- No synthesis, timing-closure or power report in the repository; no recorded DVS sensor data. All results are Icarus Verilog simulation with synthetic stimulus.
