# LIBELLULA-STMD: event-driven small-target detector (Python reference model)

A causal, per-event detector for tiny moving targets in event-camera (DVS) streams. It reuses LIBELLULA's ideas (activity filter, per-pixel timestamp state, tracker pool, α-β update) and adds stages taken from insect small-target-motion-detector (STMD) work. It is a software reference only; no RTL implements it yet.

**Status (v25).** Evaluated on the EV-UAV dataset (DAVIS346, static camera, tiny drones).
- v24 was tuned on `val` only.
- v25 adds glare and noise adaptation and was tuned on `train` + `val`.
- `test` was held out from all tuning and scored once per version.

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

## Results (EV-UAV test split, 24 sequences, 2.07 M events)

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

## Hardware budget (scripts/hw_estimate.py, v25 config, 346×260 sensor)

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
python3 scripts/quick.py  path/to/EV-UAV/test "$(cat configs/selected.json)"  # metrics + stage pass rates
python3 scripts/check_metrics.py path/to/EV-UAV/val 6                        # scorer cross-check
TRAIN_DIR=path/to/EV-UAV/train VAL_DIR=path/to/EV-UAV/val scripts/search_v25.sh   # v25 tuning (≈45 min, 2 cores)
python3 scripts/final_eval_v25.py path/to/EV-UAV/train path/to/EV-UAV/val path/to/EV-UAV/test
```

- `configs/selected.json` is v25 and `configs/selected_v24.json` is v24.
- Search records (every configuration evaluated, with per-sequence counts) are in `results/search/*.jsonl.gz`.
- The EV-UAV data is not included. It comes from github.com/ChenYichen9527/Ev-UAV, with files hosted on Google Drive or Baidu.

## References

- Wiederman, O'Carroll, Shoemaker 2008, *A model for the detection of moving targets in visual clutter inspired by insect physiology*, PLoS ONE. https://pmc.ncbi.nlm.nih.gov/articles/PMC2464731
- vSTMD (2025), https://arxiv.org/abs/2501.13054
- EV-UAV / EV-SpSegNet (2025), https://arxiv.org/abs/2506.23575
- M²E-UAV (2026), https://arxiv.org/abs/2605.10496
