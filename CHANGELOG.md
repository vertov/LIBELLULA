# Changelog

## v27 — 2026-10-14

`stmd/` engineering round: the rest of the small-target pipeline in RTL, the deployability items from v26 closed, one new operating point. **The v22 core pipeline (`rtl/libellula_*`) is unchanged.** `test` was neither used for decisions nor scored.

- **Back-end RTL** (`rtl/stmd_backend.v`): ESTMD polarity correlation, cell accumulators with the 9×9 ring surround, the eight-track pool (α-β update, 32-step restoring divider for the velocity measurement, confirmation, stationarity, spawn/replace) and labelling. `tb/tb_stmd_pipeline.v` chains the front end into it. On the four vector scenes (88 000 events) the chained RTL matches the C reference on every candidate flag, every label and the number of confirmed-track records (`make -C sim stmd_pipe`, `stmd/results/stmd_rtl_replay_v27.txt`). Verilator lint clean. Worst case about 265 cycles per candidate event, dominated by the 162-cycle surround loop. Yosys 0.33 generic estimate for a 32×32 instance: 82 247 generic cells, 763 flip-flops, 29 memories (`stmd/results/yosys_stmd_backend_32x32.log`), against 7 085 cells for the front end; the five 64-bit multipliers of the tracker and the 64-bit score arithmetic dominate (about 28 000 XOR/XNOR cells) and are written at C widths, not narrowed or shared, so this is an upper bound for the arithmetic, and the ABC pass took about an hour. Not timed or placed.
- **Division removal** (C model and both modules): decay tables are indexed by `age >> shift` with power-of-two buckets; noise-rate tables by `Ng >> rate_shift`; the only remaining division is the velocity measurement, at most once per 50 ms per track, done sequentially in RTL. C/Python agreement after the change: 99.85 % of labels on the held-out split, IoU 0.762 vs 0.764 (`stmd/results/c_equivalence_holdout_v27.txt`).
- **16-bit timestamps made safe.** Explicit expiry rule (any entry older than 4095 ms reads as empty) in C and RTL; a reset sweep clears every valid bit before `in_ready`; an idle-cycle sweep expires one pixel, one cell and one track per idle cycle. The long-gap vector scene now retraces the target path 65.54 s later so stale state is met at wrapped ages of 0–2000 ms. `make -C sim stmd_sweep_neg` strips the sweeps and shows 387 front-end and 33 back-end mismatches (`stmd/results/stmd_sweep_negative_v27.txt`); it runs in CI and must fail.
- **Vectors** (`tb/vectors/stmd_fe/`): the expected word now carries the C response and candidate bits and the label; `fe_params.vh` carries every back-end constant; `lut_acc.hex` added.
- **Operating point** `configs/v27_segmentation_ft.json` (held-out split, scored once, `stmd/results/final_v27.json`): IoU 0.807, Pd 0.837, 4.5 false tracks/min against 0.764 / 0.888 / 20.6 for the v26 segmentation point. The false-track reduction is outside the 95 % intervals; the IoU and Pd changes are not. `selected.json` stays at the v26 segmentation point.
- **Ablation.** ESTMD off is inside the intervals on both points (IoU 0.759 / 0.809) and cuts state from 1 027 to 654 kB at 346×260 (`stmd/results/hw_v26_segmentation_noestmd.json`).
- **CI:** the chained replay and the negative sweep test are new steps; the lint step covers both modules.
- **Not done:** coarse surround in RTL (the throughput fix), timing/placement/power, sensor-in-the-loop, the learned baseline (no GPU).

## v26 — 2026-10-14

`stmd/` engineering round: held-out protocol, track-level metrics, two operating points, a fixed-point C reference, a cheaper surround, and the first RTL for the small-target front end. **The v22 core pipeline (`rtl/libellula_*`) is unchanged.** `test` was neither used for decisions nor scored.

- **Protocol.** New held-out split of 20 `train` sequences, stratified by raw-data statistics (`stmd/splits/holdout_v26.txt`). All tuning on the other 79 `train` sequences plus `val`; the held-out split scored once per variant. Fixed `tune.py`: base-config keys absent from the search space were dropped (this re-enabled ESTMD in v25 without notice).
- **Track-level metrics** (`stmd/libstmd/trackmetrics.py`, `stmd/docs/TRACK_METRICS.md`): target detection rate, time to first detection, window coverage, false tracks per minute, false-track time, localisation error. The model now emits a confirmed-track log.
- **Two operating points** (held-out split, 95 % intervals in `stmd/results/final_v26.json`):
  - *segmentation* (`configs/v26_segmentation.json`, also `selected.json`): IoU 0.764, Pd 0.888, 20.6 false tracks/min. Statistically indistinguishable from v25 (0.761 / 0.899 / 16.5).
  - *alarm* (`configs/v26_alarm.json`): 3.0 false tracks/min (budget 2), target detection 0.80, window coverage 0.645. The reduction in false tracks is paid for on the dense-noise sequences, where coverage drops to 0.09–0.24.
- **Ablations** (no re-tune): glare adaptation carries precision on the segmentation point (IoU 0.764 → 0.553 without it); noise adaptation raises detection on both points at a false-track cost; `lab_requires_baf` lifts precision 0.78 → 0.96 on the alarm point for 0.04 Pd.
- **Fixed-point C reference** (`stmd/cref/stmd_ref.c`, `stmd/docs/CREF.md`): integer-only, documented widths, telescoping table decays, rate tables instead of per-event divisions. 99.8 % label agreement with the Python model on the held-out split; pooled metrics within 0.004 IoU / 0.02 Pd. Two bugs caught by the equivalence test.
- **Cheaper surround** (`sur_mode=1`): coarse 3×3 grid in place of the 9×9 ring; −0.006 IoU, −0.007 Pd without re-tuning; 164 → 40 accesses per response event.
- **RTL** (`rtl/stmd_frontend.v`): per-pixel activity filter with noise adaptation, glare adaptation and flicker habituation. Bit-exact against the C model on 60 000 synthetic events (`make -C sim stmd_fe`); Verilator lint clean; Yosys 0.33 generic estimate for a 32×32 instance about 7 000 gates, 118 flip-flops, 10 memories (`stmd/results/yosys_stmd_frontend_32x32.log`). Not timed, not placed; needs a reset sweep and a timestamp sweep in hardware.
- **Hardware budget at C widths:** about 1.0 MB of state at 346×260 (v25's 652 kB assumed 12-bit timestamps plus a sweep).
- **CI:** new steps run the front-end lint and replay, build the C reference with `-Werror`, and regenerate the RTL vectors to check they match the committed ones.
- **Skipped:** the learned causal baseline (no GPU).

## v25 — 2026-10-14

`stmd/` reference model: glare and noise adaptation, re-tuned on EV-UAV `train` + `val`. **RTL behaviour is unchanged from v22**; the edits outside `stmd/` are this entry, the README section and version labels.

- **New stages.**
  - *Glare adaptation:* a slow per-region event-rate estimate (16×16 px, τ 4 s) mutes regions whose rate stays above 1.5 events/px/s, so they cannot seed candidates or be labelled.
  - *Noise adaptation:* a global background-rate estimate shortens the activity-filter window, requires two supporting neighbours above 0.3 events/px/s, and raises the candidate threshold.
- **Protocol.**
  - 550 configurations searched on `train` + `val` (123 sequences); `test` held out.
  - The glare and noise stages were designed after seeing v24's failures on test sequences; their parameters were tuned without test.
- **Results on EV-UAV test.**
  - v25: IoU 0.813, recall 0.934, Pd 0.902.
  - v24: 0.667, 0.845, 0.883.
  - False-positive events fell from 19.0 k to 10.6 k. False-alarm clusters per 50 ms window rose from 0.64 to 1.47, mostly in the two dense-noise sequences.
- **Glare.** test_008 IoU 0.12 → 0.52; false-positive events on that sequence 15.5 k → 1.8 k.
- **Noise.** On test_022 and test_023, recall improves (0.59 → 0.86 and 0.50 → 0.82) but precision falls on test_022. Pooled test IoU is unchanged with noise adaptation switched off. Dense noise remains the main failure.
- **ESTMD.** The ESTMD stage is on as a mild weight in the v25 config; switching it off changes the train+val objective by under 1 % and saves about 260 kB of state.
- **New scripts.** `search_v25.sh`, `final_eval_v25.py` and `split_profile.py`. `tune.py` accepts several data folders.
- **Configs.** `configs/selected.json` is v25; `configs/selected_v24.json` is kept.

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
