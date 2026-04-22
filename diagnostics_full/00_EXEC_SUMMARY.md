# Full Diagnostic Summary

**Run date:** 2026-04-11
**Simulator:** Icarus Verilog 12.0 / vvp
**Rerun command:** `python3 diagnostics_full/scripts/run_full_diagnostic.py`

---

## One-Sentence Verdict

The LIBELLULA RTL never produces predictions because `LEAK_SHIFT=2` with `THRESH=16` creates a mathematical fixed point at accumulator state=4, which is permanently below the spike threshold of 16, leaving the entire motion-prediction pipeline permanently dormant.

---

## Files Added / Changed

**New diagnostic benches (tb/):**
- `tb/tb_pred_valid_golden.v` — golden-path end-to-end bench
- `tb/tb_pred_must_fire.v` — hash-aligned must-fire bench
- `tb/tb_lif_unit_diag.v` — isolated LIF unit bench
- `tb/tb_scan_hash_diag.v` — scan/hash contract bench

**RTL modification:**
- `rtl/libellula_top.v` — `LIBELLULA_STAGE_DIAG` instrumentation (lines 188–256)

**Diagnostic scripts (diagnostics_full/scripts/):**
- `run_full_diagnostic.py`, `run_repro_phase.py`, `run_lif_unit.py`
- `run_scan_contract.py`, `run_stage_activity.py`, `run_param_sweep.py`
- `check_invariants.py`, `gate_analysis.py`

**Machine-readable outputs (diagnostics_full/out/):**
- `repro_runs.csv`, `lif_unit_results.csv`, `scan_hash_results.csv`
- `stage_activity.csv`, `param_sweep_results.csv`, `invariant_results.csv`
- `emission_gate_results.csv`, `end_to_end_results.csv`, `final_ranked_causes.json`

**Makefile:** `sim/Makefile` updated with `full-diagnostic` target.

---

## Phase Status

| Phase | Description | Status |
|-------|-------------|--------|
| 0 | Repo map and signal inventory | PASS |
| 1 | Reproduce prior failure | PASS (confirmed negative) |
| 2 | LIF unit analysis | PASS (proved non-spiking) |
| 3 | Scan/hash contract analysis | PASS (contract identified, not sufficient) |
| 4 | Stage activity trace | PASS (earliest dead stage: lif_tile_tmux) |
| 5 | Parameter sensitivity | PASS (dead across legal space; LEAK_SHIFT>=4 needed) |
| 6 | Internal state invariants | PASS (arithmetic correct; parameters wrong) |
| 7 | Emission gate analysis | PASS (primary gate: spike comparator in LIF) |
| 8 | End-to-end retest | SKIPPED (no pred_valid observed in any phase) |
| 9 | Final root cause | PASS |

---

## Critical Evidence (independently verified)

```
# LIF with default params (scan held, 64 hits):
LIF_RESULT peak=4 spiked=0 leak_shift=2 thresh=16

# Golden path (64 events, free-running scan):
PHASE1_RESULT pred_count=0 events_sent=64 total_cycle=416
PHASE2_STAGE lif=0 delay=0 reichardt=0 burst=0 pred=0

# Must-fire bench (64 hash-aligned events):
PHASE4_RESULT status=FAIL pred_count=0 total_cycle=16498

# LIF with LEAK_SHIFT=4 (scan held, fixes the bug):
LIF_RESULT peak=15 spiked=1 first_spike=65 leak_shift=4 thresh=16
```

---

## Root Cause (one line)

`LEAK_SHIFT=2` causes the LIF accumulator fixed point (4) to be below `THRESH=16`; changing `LEAK_SHIFT` to 4 is the minimum repair.
