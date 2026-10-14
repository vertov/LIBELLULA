# LIBELLULA-STMD: event-driven small-target detector (Python reference model)

A causal, per-event detector for tiny moving targets in event-camera (DVS) streams. It reuses LIBELLULA's ideas (activity filter, per-pixel timestamp state, tracker pool, α-β update) and adds stages taken from insect small-target-motion-detector (STMD) work. This is a software reference; there is no RTL yet.

Status: evaluated on the EV-UAV dataset (DAVIS346, static camera, tiny drones). All parameters were tuned on the `val` split; `test` was scored once at the end.

## Pipeline (libstmd/model.py)

| Stage | What it does | Origin |
|---|---|---|
| 1. Background-activity filter | event passes if one of its 8 neighbours fired within `T_ba` | LIBELLULA `activity_filter.v` |
| 2. Flicker habituation | per-pixel leaky count of polarity reversals; pixels that keep reversing (lights, glare) are suppressed | insect adaptation; new |
| 3. ESTMD polarity correlation (optional) | event responds if the opposite polarity fired at the pixel `tau_min..tau_max` earlier (OFF-then-ON signature of a small dark object) | Wiederman et al. 2008 |
| 4. Centre-surround inhibition | response in a 3×3-cell centre minus responses (`k_inh`) and raw activity (`k_act`) in the surrounding ring | STMD lateral inhibition |
| 5. Tracker pool | gated tracks with α-β position/velocity; confirmation needs hits, time and displacement; tracks that stop moving for `T_stat` stop labelling | LIBELLULA `tracker_pool` |
| 6. Labelling | event labelled target if within `R_lab` of a confirmed, moving track | — |

## Results (EV-UAV test split, 24 sequences, 2.07 M events)

Scored with a port of the authors' evaluator (`libstmd/metrics.py`). The port matches a line-by-line transcription of their `utils/eval.py` exactly (`scripts/check_metrics.py`).

| | IoU | ACC (target-event recall) | Pd (per 50 ms, per target) |
|---|---:|---:|---:|
| This model, selected on val (no ESTMD stage) | **0.667** [0.48–0.87] | **0.845** [0.79–0.91] | **0.883** [0.84–0.92] |
| This model, all stages | 0.670 [0.52–0.83] | 0.780 [0.69–0.88] | 0.858 [0.80–0.90] |
| EV-SpSegNet (paper's trained network) | 0.552 | 0.650 | 0.775 |

Brackets are 95 % bootstrap intervals over sequences. The paper's IoU sits inside this model's interval; its ACC and Pd do not. The paper's Fa column can't be reproduced with the released scorer: 9 of its 14 values exceed 52×10⁻⁴, the most the scorer can return on this test set (`scripts/fa_bound.py`). False alarms are therefore reported here as false clusters per 50 ms window: 0.64 for the selected model (Fa by the released code: 7.1e-6).

Not a like-for-like comparison:
- This model is causal and online. EV-SpSegNet segments whole 8 s clips at once on a GPU.
- This model has 33 hand-set parameters (including on/off switches) chosen by searching ~1,150 configurations on val. The network has 4.0 M learned weights trained on the train split.

### Ablations (each variant re-tuned on val, then scored once on test)

See `results/final_table.md`.
- Two stages carry the result. Without centre-surround inhibition, val IoU+Pd falls from 1.71 to 1.38. Without the tracker it falls to 1.32.
- The ESTMD polarity correlation gives no measurable benefit, even though target events show the signature far more often than background (55 % vs 12 %). Removing it scored slightly higher on val, which is why the selected model omits it.
- Flicker habituation, the activity surround term and the stationarity check each help on val. On test their effects are mixed and within sequence-to-sequence noise.
- The val-to-test drop (IoU 0.84 to 0.67) comes mainly from three test sequences:
  - test_008: sun glare, IoU 0.12.
  - test_022 and test_023: dense low-light noise, IoU 0.51 and 0.43.

## Hardware budget (scripts/hw_estimate.py, selected config, 346×260 sensor)

- State memory: about 388 kB, mostly 29 bits per pixel (two 12-bit timestamps, a 4-bit flip count and the last polarity) and 10 k cell accumulators. The all-stages variant needs about 651 kB. Either fits in block RAM on mid-range FPGAs, but not on the smallest parts.
- Memory accesses: about 75 state accesses per event on average. Each response event costs 164 accesses because the surround is a 9×9-cell ring, so this is the stage to restructure for hardware, for example as a coarser surround grid.
- Event rates: the EV-UAV mean is about 11 k events/s, and the busiest sequence about 78 k events/s.
- The reference uses floating-point `exp()` decays. A fixed-point, bit-exact C version is the next step before RTL.

## Limitations

- One dataset, static camera, daylight sky scenes. Ego-motion is untested; the moving-platform benchmark M²E-UAV has not released its data.
- Glare and dense sensor noise are the open failure cases (`scripts/failure_diag.py`):
  - **Glare.** On test_008, 97 % of the 15.5 k false-positive events fall in 14 persistently hot 8×8-px cells around the sun. These account for 79 % of all false positives on test. If they were removed with target recall unchanged, pooled test IoU would be about 0.80; this is an estimate, not a measurement. The likely fix is slow per-region adaptation, which suppresses a cell whose event rate stays high for seconds. A target crosses a cell in well under a second.
  - **Dense noise.** On test_022 and test_023 the background runs at about 0.85 events/px/s. A target delivers only about 5× the background events in a 12×12-px box per 50 ms, against 12–40× in clean scenes. The 80 ms activity-filter window then passes about 40 % of noise. Making that window and the detection threshold adapt to the measured noise rate should recover part of the loss, but not all of it, because the sensor signal-to-noise ratio sets a floor. `val` has no scene this noisy, so tuning a fix needs more data, for example part of the EV-UAV train split.
- Design history: the stationarity check was added after looking at failures on test sequences, before val was available. Every parameter was tuned on val only.

## Run

```bash
pip install -r requirements.txt
python3 tests/smoke.py                                                      # data-free check (synthetic target)
python3 scripts/quick.py  path/to/EV-UAV/test '{"use_estmd": false}'      # metrics + stage pass rates
python3 scripts/perseq.py path/to/EV-UAV/test "$(cat configs/selected.json)"
python3 scripts/check_metrics.py path/to/EV-UAV/val 6                       # scorer cross-check
VAL_DIR=path/to/EV-UAV/val scripts/search.sh full ; VAL_DIR=... scripts/ablate.sh   # val tuning (≈45 min, 2 cores)
python3 scripts/final_eval.py path/to/EV-UAV/val path/to/EV-UAV/test
```

Search records (every configuration evaluated, with per-sequence counts) are in `results/search/*.jsonl.gz`. The EV-UAV data is not included. It comes from github.com/ChenYichen9527/Ev-UAV, with the files hosted on Google Drive or Baidu.

## References

- Wiederman, O'Carroll, Shoemaker 2008, *A model for the detection of moving targets in visual clutter inspired by insect physiology*, PLoS ONE. https://pmc.ncbi.nlm.nih.gov/articles/PMC2464731
- vSTMD (2025), https://arxiv.org/abs/2501.13054
- EV-UAV / EV-SpSegNet (2025), https://arxiv.org/abs/2506.23575
- M²E-UAV (2026), https://arxiv.org/abs/2605.10496
