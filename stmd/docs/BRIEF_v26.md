# Brief: LIBELLULA v26 — small-target detector, next engineering round

You are taking over engineering work on LIBELLULA, a public repository at https://github.com/vertov/LIBELLULA (owner: Oliver Hockenhull). Read this brief fully before starting. Work carefully and report plainly; this project has a history of overstated claims that later had to be corrected, and the standard now is that every number in the repo is reproducible from a script and a stored output.

## 1. What exists (state at v25, commit `c35139a`)

**RTL core (`rtl/`, `tb/`, `sim/`).** A synthesizable Verilog-2001 pipeline for AER/DVS event streams: activity filter, time-multiplexed LIF tiles, delay lattice, Reichardt direction detector, burst gate, tracker pool, α-β predictor, AXI4-Stream wrappers.
- Behaviour has been unchanged since v22.
- `make -C sim test` runs 38 core benches (Icarus Verilog 12); `make -C sim axi` runs 4 AXI benches; `make -C sim lint` runs Verilator (CI uses 5.020).
- CI is `.github/workflows/ci.yml`. Benches signal failure by printing FAIL/TIMEOUT, CI greps for it, and the workflow runs bash with pipefail.

**Python small-target detector (`stmd/`).** This is the active line of work. It is a causal, per-event reference model (`stmd/libstmd/model.py`) with these stages:
1. Background-activity filter.
2. Flicker habituation.
3. Optional ESTMD polarity correlation.
4. Centre-surround inhibition on a cell grid (responses and raw activity).
5. Tracker pool with α-β update and a stationarity check.
6. Event labelling near confirmed tracks.
7. Glare adaptation: slow per-region rate, regions muted above a threshold.
8. Noise adaptation: a global background-rate estimate drives the filter window, the support count and the threshold.

The rest of `stmd/`:
- Parameters: 43, including on/off switches. `stmd/configs/selected.json` is v25; `selected_v24.json` is v24.
- Evaluator: `stmd/libstmd/metrics.py` ports the EV-UAV authors' scorer (IoU, ACC, Pd, Fa). `stmd/scripts/check_metrics.py` verifies it against a line-by-line transcription of their `utils/eval.py`; keep that check passing.
- Tuning: `stmd/scripts/tune.py` (random search, per-sequence raw counts), `search_v25.sh`, `final_eval_v25.py`, `bootstrap.py`, `hw_estimate.py`, `failure_diag.py`, `fp_spillover.py` (output in `stmd/results/fp_spillover.txt`).
- Tests and docs: `stmd/tests/smoke.py` is a data-free synthetic test run in CI. `stmd/README.md` holds results, ablations and caveats; read it.

**Data: EV-UAV.** Static DAVIS346 camera (346×260), tiny drones, per-event labels. Source: https://github.com/ChenYichen9527/Ev-UAV (files on Google Drive or Baidu).
- Splits: `train` 99, `val` 24, `test` 24 sequences of about 8 s each.
- Each `.npz` holds `ev`, a structured array with x, y, t (ms, float), p (0/1), label (0/1) and name (target id, 0 = background), plus `ev_loc` (integer-ms t used by the scorer).
- The data is **not** in the repo and must not be committed. The operator will tell you where the folders are. If you cannot reach them, say so and do the data-free tasks.

**Results so far (EV-UAV test).**

| Model | IoU | Recall | Pd |
|---|---|---|---|
| v25 | 0.813 | 0.934 | 0.902 |
| v24 | 0.667 | 0.845 | 0.883 |
| EV-SpSegNet, published | 0.552 | 0.650 | 0.775 |

The comparison is not like-for-like: this model is causal with hand-set parameters, while EV-SpSegNet is an offline, whole-clip GPU network. The paper's Fa column cannot be reproduced with the released scorer (`stmd/scripts/fa_bound.py`).

**Known findings.**
- **What carries the result:** centre-surround inhibition and the tracker. The ESTMD polarity correlation gives under 1 % benefit and costs about 260 kB of state.
- **Glare:** largely fixed by regional adaptation.
- **Dense low-light noise** (test_022/023; train_092–098) is the main failure. Noise adaptation raises recall but adds scattered false alarms. 20–60 % of false events in those scenes are noise pixels beside the real target, swept into the labelling box. Setting `lab_requires_baf: true` cuts false clusters per 50 ms window 5–9× on the train noise scenes, at a small Pd cost and a large loss of event recall (`stmd/results/fp_spillover.txt`).
- **Hardware estimate (v25 config):** about 652 kB of state, about 47 state accesses per event, and 164 accesses per response event from the 9×9-cell surround.

**The `test` split is spent.** It has been scored for two versions, and the v24 stationarity check and the v25 glare and noise stages were designed after seeing test failures. Do not use `test` for any decision. Do not score it again unless the operator asks.

## 2. Rules

1. **Data discipline.**
   - First create a new held-out split: choose 20 `train` sequences deterministically (fixed seed, stratified to include at least 2 glare and 2 dense-noise sequences; `stmd/scripts/split_profile.py` profiles them).
   - Record the list in `stmd/splits/holdout_v26.txt`.
   - Tune only on the remaining 79 `train` plus `val`. Score the held-out set once per finished variant and report it.
2. **Evidence.**
   - Every number you put in README, CHANGELOG or a report must be produced by a committed script, with its output stored under `stmd/results/`.
   - Give 95 % bootstrap intervals over sequences for headline metrics.
   - Report negative and null results as plainly as positive ones.
3. **Ablations.** Every new stage gets an ablation: switch it off and, where feasible, re-tune locally.
4. **No silent behaviour changes.**
   - The RTL core must keep passing all existing benches.
   - Any new RTL needs its own benches, wired into `sim/Makefile` and CI, with failure signalled by printed FAIL/TIMEOUT.
5. **Claims.**
   - No promotional language and no claims about frame-based cameras; the design is event-camera only.
   - Simulation results are labelled as simulation. Synthesis numbers are labelled with tool, version and target.
   - Unverified estimates are labelled as estimates.
6. **Register.** Write plainly and concisely. No hype, no restating your own correctness, no rhetorical flourishes.

## 3. Tasks, in priority order

Stop and report if a task turns out larger than expected. Finished earlier tasks are worth more than half-finished later ones.

**T0. Re-establish the baseline.**
- Clone the repo.
- Run the RTL suite (`make -C sim test axi lint`), `stmd/tests/smoke.py` and `stmd/scripts/check_metrics.py`.
- With data available, reproduce the v25 train and val numbers from `stmd/results/final_v25.json`. Do not run test.
- Fix a known harness bug: in `stmd/scripts/tune.py`, `sample()` drops base-config keys that are absent from `SPACE`. That is how `use_estmd` silently reverted to its default in the v25 search. Base keys not in `SPACE` must carry over unchanged.

**T1. Held-out split.** As in Rule 1.

**T2. Detection-level metrics.** The EV-UAV scorer is event-segmentation oriented and counts each stray noise pixel as a separate false alarm. Add metrics a user of a detector cares about, with a short definition document:
- track-level detection rate (fraction of ground-truth targets detected, and time to first detection);
- false tracks per minute (confirmed tracks with no ground-truth target within a gate);
- localisation error of confirmed tracks.

Keep the EV-UAV metrics alongside for continuity.

**T3. Two operating points.** Tune and report two configurations:
- *segmentation*: maximise IoU + Pd, as before;
- *alarm*: maximise track detection subject to a false-track budget you state.

Include `lab_requires_baf` and the noise-adaptation parameters in the alarm search. Report both on the held-out set, with per-sequence tables for the glare and dense-noise sequences.

**T4. Fixed-point, bit-exact C reference.** Port the alarm and segmentation pipelines to C99:
- integer timestamps and integer state;
- leaky decays via shift or lookup table instead of `exp()`;
- documented bit widths matching `stmd/scripts/hw_estimate.py`, or updating it.

Provide a CLI that reads an event file and writes per-event labels and track outputs, plus a Python binding or subprocess wrapper. Add an equivalence test against the Python model and report agreement: identical decisions where intended, otherwise a quantified difference in metrics. The C model becomes the golden reference for RTL.

**T5. Cheaper surround.** The 9×9-cell surround dominates memory traffic. Try at least one cheaper structure, such as a coarser second grid, a separable or running-sum surround, or a smaller ring with re-tuning. Measure the accuracy change on the held-out set and the change in accesses per event.

**T6. RTL for the front end.** Using the C model as golden, implement in Verilog-2001:
- the activity filter with noise adaptation, reusing or extending `rtl/activity_filter.v`;
- glare adaptation;
- flicker habituation.

Requirements:
- Benches replay recorded event streams (short excerpts exported by a script; do not commit raw dataset files beyond what the dataset licence allows, so prefer synthetic or derived vectors) and check bit-exact agreement with the C model.
- Verilator lint must be clean.
- If Yosys is available, report generic resource estimates, labelled as such.
- Do not touch the existing core pipeline's behaviour.

**T7 (optional, only if compute allows). Learned causal baseline.** Train a small causal learned detector on the 79 training sequences and score it on the held-out set with the same scorers. This gives a fair comparison instead of a comparison against published offline numbers. If no GPU is available, say so and skip it.

## 4. Out of scope

- **Moving-camera performance.** No suitable data exists in hand; the M²E-UAV benchmark, https://arxiv.org/abs/2605.10496, had not released data at last check. Do not claim anything about ego-motion. If you find a released moving-camera event dataset with labels, report it without integrating it.
- **The dense-noise floor.** At about 5 target events per background event near the target, filtering cannot recover everything. Do not present tuning gains on noisy scenes as solving it.
- Patent, licensing or commercial matters.

## 5. Delivery: replace the repo contents with the new version

- Commit directly to `main` of `vertov/LIBELLULA` as **v26**, superseding v25. Do not create branches; the owner wants a single current version.
  - Update the version labels the way v23–v25 did: `grep -rn "Core v25"`, plus `sim/Makefile` tags and `ENGINEERING_OVERVIEW.md` revision lines.
  - Add a v26 entry at the top of `CHANGELOG.md`.
  - Update `stmd/README.md` and the `stmd` section of the top-level `README.md`.
- Before pushing:
  - `git fetch origin main`; if `main` moved, rebase and re-run checks.
  - Run the full RTL suite, lint, the smoke test and the metric check.
  - After pushing, confirm the GitHub Actions run is green and link it.
- If you cannot push (permissions), produce a `git bundle` or patch series against `c35139a` and say so.
- Tags may not be pushable from your environment. If not, say so; the owner can tag.

## 6. Final report (in chat, not in the repo)

Keep it short. Include:
- what changed;
- held-out results for both operating points, with intervals, against v25 on the same held-out set;
- ablations;
- what failed or was skipped and why;
- the commit and CI links.

No recap of steps.
