# LIBELLULA-STMD: event-driven small-target detector (Python reference model)

A causal, per-event detector for tiny moving targets in event-camera (DVS) streams. It reuses LIBELLULA's ideas (activity filter, per-pixel timestamp state, tracker pool, α-β update) and adds stages taken from insect small-target-motion-detector (STMD) work. It is a software reference only; no RTL implements it yet.

**Status (v26).** Evaluated on the EV-UAV dataset (DAVIS346, static camera, tiny drones).
- v24 was tuned on `val` only; v25 added glare and noise adaptation and was tuned on `train` + `val`. `test` was scored once for each.
- v26 does not touch `test`. It introduces a new held-out split (20 `train` sequences, `splits/holdout_v26.txt`), track-level metrics, two operating points tuned on the other 79 `train` sequences plus `val`, a fixed-point C reference, a cheaper surround, and a per-pixel front-end RTL module verified bit-exact against the C model. See "v26 results" below.

## Pipeline (libstmd/model.py)

| Stage | What it does | Origin |
|---|---|---|
| 1. Background-activity filter | event passes if enough of its 8 neighbours fired within `T_ba` | LIBELLULA `activity_filter.v` |
| 2. Flicker habituation | per-pixel leaky count of polarity reversals; pixels that keep reversing are suppressed | insect adaptation |
| 3. ESTMD polarity correlation (optional) | event is weighted up if the opposite polarity fired at the pixel `tau_min..tau_max` earlier (OFF-then-ON signature of a small dark object) | Wiederman et al. 2008 |
| 4. Centre-surround inhibition | response in a 3×3-cell centre minus responses (`k_inh`) and raw activity (`k_act`) in the surrounding ring | STMD lateral inhibition |
| 5. Tracker pool | gated tracks with α-β position/velocity; confirmation needs hits, time and displacement; tracks that stop moving for `T_stat` stop labelling | LIBELLULA `tracker_pool` |
| 6. Labelling | event labelled target if within `R_lab` of a confirmed, moving track | — |
| 7. Glare adaptation (v25) | slow per-region event rate (16×16 px, τ 4 s); a region whose rate stays above `G_rate` is muted, with no candidates and no labels | photoreceptor/lamina adaptation |
| 8. Noise adaptation (v25) | a global background-rate estimate shortens the stage-1 window, requires 2 supporting neighbours above `r_hi`, and raises the candidate threshold | gain control |
| 9. Coarse surround (v26, optional) | `sur_mode=1`: a second accumulator grid of `sur_k`×`sur_k` cells; surround = 3×3 coarse block minus the fine centre, 9 reads instead of 72 | — |

Stages 1, 2, 7 and 8 exist in Verilog (`rtl/stmd_frontend.v`), bit-exact against the C reference.

## v26 results (held-out split, 20 train sequences, 2.7 min of data)

All tuning used the other 79 `train` sequences plus `val`; this split was scored once per variant (`scripts/final_eval_v26.py`, `results/final_v26.json`, `results/final_v26_table.md`). Brackets are 95 % bootstrap intervals over sequences. Track metrics are defined in `docs/TRACK_METRICS.md`.

| Variant | IoU | Pd | false clusters / 50 ms | targets detected | window coverage | false tracks / min |
|---|---:|---:|---:|---:|---:|---:|
| v25 (previous release) | 0.761 [0.68–0.84] | 0.899 [0.85–0.95] | 1.50 | 0.94 | 0.828 [0.73–0.92] | 16.5 [4.9–30.8] |
| **v26 segmentation** (`configs/v26_segmentation.json`, = `selected.json`) | 0.764 [0.69–0.84] | 0.888 [0.84–0.94] | 1.40 | 0.94 | 0.804 [0.70–0.91] | 20.6 [7.1–37.9] |
| **v26 alarm** (`configs/v26_alarm.json`) | 0.664 [0.55–0.79] | 0.745 [0.62–0.87] | 3.01 | 0.80 | 0.645 [0.49–0.81] | 3.0 [0.0–6.8] |

What the numbers say:
- **Segmentation point.** Re-tuning on the larger set changed three parameters (`tau_flip_ms` 500→2000, `k_act` 2→3, `H_min` 12→5) and improved the tuning objective (1.680→1.695), but on the held-out split it is indistinguishable from v25: every difference is inside the intervals. False tracks per minute rose (16.5→20.6) because `H_min` fell and the segmentation objective does not see tracks.
- **Alarm point.** Tuned for track detection under a budget of 2 false tracks per minute (`FT_BUDGET`, penalised above). It reaches 3.0/min on the held-out split (1.86 on the tuning set), with target detection 0.80 and window coverage 0.645. The budget is paid for almost entirely on the dense-noise sequences, where coverage falls to 0.09–0.24 (table below). On clean and glare scenes it keeps coverage ≥ 0.9 and removes most glare-edge false tracks (train_033: 82.5 → 0 per minute). The parameters that moved: a 6 px gate instead of 12, 200 ms confirmation instead of 100, 2 px cells instead of 3, velocity-extended labelling (`k_vlab` 0.5), and a looser glare threshold.
- **Low light remains the limit.** No configuration found here keeps both a low false-track rate and useful coverage on the ≥ 0.5 ev/px/s sequences.

| Hard held-out sequence | v25 IoU / Pd / false tracks per min | v26 segmentation | v26 alarm | v26 alarm coverage |
|---|---|---|---|---:|
| train_029 (glare, 89 hot cells) | 0.74 / 0.94 / 105 | 0.78 / 0.94 / 120 | 0.85 / 0.92 / 30 | 0.90 |
| train_033 (glare) | 0.86 / 1.00 / 82.5 | 0.87 / 1.00 / 90 | 0.91 / 0.97 / 0 | 0.97 |
| train_044 (glare + 0.41 ev/px/s) | 0.51 / 0.90 / 22.5 | 0.49 / 0.90 / 22.5 | 0.59 / 0.55 / 0 | 0.42 |
| train_089 (noise 0.56) | 0.53 / 0.73 / 7.5 | 0.58 / 0.68 / 0 | 0.22 / 0.29 / 0 | 0.09 |
| train_090 (noise 0.58) | 0.41 / 0.66 / 7.5 | 0.47 / 0.72 / 15 | 0.21 / 0.27 / 0 | 0.09 |
| train_092 (noise 0.82) | 0.78 / 0.93 / 0 | 0.71 / 0.80 / 0 | 0.39 / 0.57 / 0 | 0.24 |

### v26 ablations (no re-tune, held-out split)

| Variant | IoU | Pd | precision | targets detected | window coverage | false tracks / min |
|---|---:|---:|---:|---:|---:|---:|
| segmentation, no glare adaptation | 0.553 | 0.888 | 0.587 | 0.94 | 0.804 | 20.3 |
| segmentation, no noise adaptation | 0.736 | 0.852 | 0.831 | 0.90 | 0.790 | 19.5 |
| segmentation, coarse surround k=3 | 0.758 | 0.881 | 0.826 | 0.94 | 0.802 | 21.8 |
| alarm, no glare adaptation | 0.664 | 0.745 | 0.782 | 0.80 | 0.645 | 3.0 |
| alarm, no noise adaptation | 0.640 | 0.684 | 0.852 | 0.68 | 0.650 | 1.9 |
| alarm, coarse surround k=3 | 0.656 | 0.746 | 0.772 | 0.80 | 0.645 | 3.75 |
| alarm, `lab_requires_baf` on | 0.684 | 0.703 | 0.957 | 0.80 | 0.645 | 3.0 |

- Glare adaptation carries precision on the segmentation point (IoU 0.764 → 0.553 without it) but does nothing for the alarm point, whose loose glare threshold (`G_rate` 4) rarely fires; the alarm point suppresses glare tracks through its tracker settings instead.
- Noise adaptation raises detection on both points (0.90 → 0.94 and 0.68 → 0.80) at the cost of false tracks (alarm: 1.9 → 3.0/min).
- The coarse surround costs 0.006 IoU and under 0.01 Pd with no re-tuning, and cuts memory accesses per response event from 164 to 40 (`results/hw_v26_segmentation_coarse.json`).
- Labelling only filter-passing events lifts precision from 0.78 to 0.96 and cuts false clusters per window from 3.0 to 0.3 without touching the track metrics; it costs 0.04 Pd.

### Fixed-point C reference (`cref/`, `docs/CREF.md`)

Integer-only C99 port of the whole pipeline with documented widths; `cref/cref.py` wraps it. On the held-out split it agrees with the Python model on 99.6 % of activity-filter decisions and 99.8 % of labels for both v26 configurations (`results/c_equivalence_holdout_v26_*.txt`); pooled metrics differ by ≤ 0.004 IoU and ≤ 0.02 Pd. Two bugs were found by the equivalence test during development (a stalled decay at high event rates, and a missing glare mute in labelling).

### Front-end RTL (`rtl/stmd_frontend.v`, `tb/tb_stmd_frontend.v`)

Per-pixel activity filter with noise adaptation, glare adaptation and flicker habituation in Verilog-2001, replaying 60 000 synthetic events from three scenes (`tb/vectors/stmd_fe/`, generated by `scripts/gen_fe_vectors.py` from the C model) with zero mismatches against the C flags (`make -C sim stmd_fe`). Verilator lint is clean (`make -C sim lint-stmd-fe`). Yosys 0.33 generic synthesis of a 32×32 instance (`make -C sim stmd_fe_synth`, `results/yosys_stmd_frontend_32x32.log`) gives about 7 000 generic gates, 118 flip-flops and 10 memories; this is an estimate from a generic library, not a timing or FPGA result. The per-pixel memories scale with the sensor: 51 bits per pixel for this module, about 560 kB at 346×260. The module needs a reset sweep of the valid bits in hardware (simulation initialises them), uses integer division by constants in two places, and does not implement the timestamp sweep that 16-bit ms timestamps need beyond 65 s.

### Hardware budget at C-model widths (`scripts/hw_estimate.py`)

With 16-bit timestamps plus valid bits and Q12.4 accumulators as in the C model: segmentation point about 1.03 MB of state and 38 accesses per event; alarm point about 1.13 MB (2 px cells); coarse surround about 26 accesses per event. The earlier v25 figures (652 kB) assumed 12-bit saturating timestamps, which need a periodic sweep; both are estimates.

### Protocol notes for v26

- `test` was not used for any decision and was not scored.
- The held-out split is drawn from `train` with a fixed seed and stratified by raw-data statistics only (`scripts/make_holdout.py`).
- Searches: segmentation 250 configurations (local refinement of v25); alarm 350 (wider, then local); records in `results/search/v26_*.jsonl.gz`. The `tune.py` bug that dropped base keys absent from the search space (which silently re-enabled ESTMD in v25) is fixed.
- The learned causal baseline (T7 of the brief) was skipped: no GPU in this environment.
- The ESTMD stage is on in both v26 configurations (carried from v25 by the fixed tuner); its effect remains under 1 % of the objective.

---

## v25 results (test split, scored once; unchanged from v25)

### EV-UAV test split, 24 sequences, 2.07 M events

Scored with a port of the authors' evaluator (`libstmd/metrics.py`). The port matches a line-by-line transcription of their `utils/eval.py` exactly (`scripts/check_metrics.py`). Brackets are 95 % bootstrap intervals over sequences.

| | IoU | ACC (target-event recall) | Pd (per 50 ms, per target) | False clusters / 50 ms |
|---|---:|---:|---:|---:|
| **v25** (train+val-tuned) | **0.813** [0.72–0.90] | **0.934** [0.91–0.95] | **0.902** [0.88–0.93] | 1.47 |
| v24 (val-tuned) | 0.667 [0.48–0.87] | 0.845 [0.79–0.91] | 0.883 [0.84–0.92] | 0.64 |
| EV-SpSegNet (paper's trained network) | 0.552 | 0.650 | 0.775 | not comparable* |

\* The paper's Fa column can't be reproduced with the released scorer: 9 of its 14 values exceed 52×10⁻⁴, the most the scorer can return on this test set (`scripts/fa_bound.py`). The released code's Fa for v25 is 1.6×10⁻⁵.

Not a like-for-like comparison:
- This model is causal and online. EV-SpSegNet segments whole 8 s clips at once on a GPU.
- This model has 43 hand-set parameters (including on/off switches). The network has 4.0 M learned weights trained on `train`.
- The other 13 systems in the paper's table score lower than EV-SpSegNet on all three of IoU, ACC and Pd.

### What the v25 fixes did (`results/final_v25_table.md`, `results/final_v25.json`)

| Test sequence | v24 IoU / recall / precision | v25 IoU / recall / precision | False clusters / 50 ms, v24 → v25 |
|---|---|---|---|
| test_008 (sun glare) | 0.12 / 0.95 / 0.12 | 0.52 / 0.94 / 0.54 | 2.4 → 2.3 |
| test_022 (dense noise) | 0.51 / 0.59 / 0.78 | 0.51 / 0.86 / 0.55 | 2.4 → 10.5 |
| test_023 (dense noise) | 0.43 / 0.50 / 0.74 | 0.59 / 0.82 / 0.68 | 2.4 → 6.4 |

- **Glare is largely fixed.** False-positive events on test_008 fall from 15.5 k to 1.8 k; three quarters of the remainder still sit in the glare region. Switching glare adaptation off (no re-tuning) drops pooled test IoU from 0.813 to 0.720.
- **Noise is traded, not fixed.** Noise adaptation finds the target far more often (test_022 Pd 0.53 → 0.78) but adds scattered false-alarm clusters. Pooled test IoU is unchanged with it switched off (0.816). That is why false clusters per window rose overall even though false-positive events fell from 19.0 k to 10.6 k. At about 5 target events per background event in the target's neighbourhood, the sensor's signal-to-noise ratio is the limit.
- **ESTMD stage.**
  - In v24, switching the ESTMD stage off scored best on `val`.
  - The v25 search left it on as a mild weight (it was not in the search space, so its default applied).
  - With it switched off, the train+val objective changes by under 1 % (1.671 vs 1.680). Switching it off would save about 260 kB of state memory.
  - Test was not scored for that variant.

### v24 ablations (each variant re-tuned on val, then scored once on test)

See `results/final_table.md`.
- Centre-surround inhibition and the tracker carry the result. Without them, val IoU+Pd falls from 1.71 to 1.38 and 1.32 respectively.
- The ESTMD polarity correlation gives no measurable benefit, even though target events show the signature far more often than background (55 % vs 12 %).

## Hardware budget as reported in v25 (12-bit saturating timestamps; superseded by the C-model widths above)

- State memory: about 652 kB.
  - 53 bits per pixel: four 12-bit timestamps, a 4-bit flip count and the last polarity.
  - Plus 10 k cell accumulators and 374 glare cells.
  - About 390 kB with the ESTMD stage off.
- Memory accesses: about 47 state accesses per event on average. Each response event costs 164 accesses because of the 9×9-cell surround ring, so the surround is the stage to restructure for hardware.
- Event rates: the EV-UAV mean is about 11 k events/s, and the busiest sequence about 78 k events/s.
- Arithmetic: the reference uses floating-point `exp()` decays. A fixed-point, bit-exact C version is the next step before RTL.

## Limitations and protocol notes

- **Scope.** One dataset, static camera, daylight sky scenes. Ego-motion is untested; the moving-platform benchmark M²E-UAV has not released its data.
- **Noise.** Dense low-light noise remains the main failure.
- **Test-informed design.**
  - The stationarity check (v24) and the glare and noise stages (v25) were designed after seeing failures on test sequences.
  - Their parameters were tuned without test: on `val` in v24, on `train` + `val` in v25.
  - Test has now been scored for two versions, so the second score is not a first look.
- **Train as a check.** v24, which never saw `train`, scored IoU 0.679 on it, close to its 0.667 on test.

## Run

```bash
pip install -r requirements.txt
python3 tests/smoke.py                                                       # data-free check (synthetic target)
python3 scripts/check_metrics.py path/to/EV-UAV/val 6                        # scorer cross-check
python3 scripts/reproduce_v25.py  path/to/EV-UAV/train path/to/EV-UAV/val    # v25 train/val numbers (no test)
python3 scripts/eval_split.py configs/v26_alarm.json path/to/EV-UAV/train --only splits/holdout_v26.txt --perseq
TRAIN_DIR=... VAL_DIR=... scripts/search_v26.sh                              # both operating points (≈3 h, 2 cores)
python3 scripts/final_eval_v26.py path/to/EV-UAV/train                       # held-out scoring + ablations
python3 scripts/c_equivalence.py configs/v26_segmentation.json path/to/EV-UAV/train --only splits/holdout_v26.txt
python3 scripts/gen_fe_vectors.py configs/selected.json ../tb/vectors/stmd_fe 12000   # RTL vectors from the C model
make -C ../sim stmd_fe lint-stmd-fe stmd_fe_synth                            # RTL replay, lint, Yosys estimate
```

- `configs/selected.json` is v25 and `configs/selected_v24.json` is v24.
- Search records (every configuration evaluated, with per-sequence counts) are in `results/search/*.jsonl.gz`.
- The EV-UAV data is not included. It comes from github.com/ChenYichen9527/Ev-UAV, with files hosted on Google Drive or Baidu.

## References

- Wiederman, O'Carroll, Shoemaker 2008, *A model for the detection of moving targets in visual clutter inspired by insect physiology*, PLoS ONE. https://pmc.ncbi.nlm.nih.gov/articles/PMC2464731
- vSTMD (2025), https://arxiv.org/abs/2501.13054
- EV-UAV / EV-SpSegNet (2025), https://arxiv.org/abs/2506.23575
- M²E-UAV (2026), https://arxiv.org/abs/2605.10496
