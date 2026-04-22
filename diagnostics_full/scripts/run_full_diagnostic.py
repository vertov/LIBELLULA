#!/usr/bin/env python3
"""
Full diagnostic runner for LIBELLULA adversarial verification.

Usage (from repo root):
    python3 diagnostics_full/scripts/run_full_diagnostic.py

Or via make:
    make -C sim full-diagnostic

Phases:
  Phase 1  - Reproduce prior failure (golden-path + must-fire)
  Phase 2  - LIF unit analysis (accumulator sweep)
  Phase 3  - Scan/hash contract analysis
  Phase 4  - Stage activity trace
  Phase 5  - Parameter sensitivity sweep
  Phase 6  - Internal state invariants
  Phase 7  - Emission gate analysis

Phase 8 (end-to-end retest) is skipped when no pred_valid is observed.
Phase 9 (final root cause) is static — read diagnostics_full/10_FINAL_ROOT_CAUSE.md.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

STEPS = [
    ("phase1_repro",        ["python3", "diagnostics_full/scripts/run_repro_phase.py"]),
    ("phase2_lif_unit",     ["python3", "diagnostics_full/scripts/run_lif_unit.py"]),
    ("phase3_scan_contract",["python3", "diagnostics_full/scripts/run_scan_contract.py"]),
    ("phase4_stage_activity",["python3", "diagnostics_full/scripts/run_stage_activity.py"]),
    ("phase5_param_sweep",  ["python3", "diagnostics_full/scripts/run_param_sweep.py"]),
    ("phase6_invariants",   ["python3", "diagnostics_full/scripts/check_invariants.py"]),
    ("phase7_gate_analysis",["python3", "diagnostics_full/scripts/gate_analysis.py"]),
]


def main() -> None:
    passed: list[str] = []
    failed: list[str] = []

    for name, cmd in STEPS:
        print(f"\n{'='*60}")
        print(f"=== Running {name} ===")
        print(f"{'='*60}")
        result = subprocess.run(cmd, cwd=REPO)
        if result.returncode == 0:
            passed.append(name)
            print(f"  -> {name}: DONE")
        else:
            failed.append(name)
            print(f"  -> {name}: FAILED (returncode={result.returncode})")

    print(f"\n{'='*60}")
    print("=== DIAGNOSTIC SUMMARY ===")
    print(f"  Passed: {len(passed)}/{len(STEPS)}")
    for p in passed:
        print(f"    PASS  {p}")
    for f in failed:
        print(f"    FAIL  {f}")
    print()
    print("Key outputs:")
    out = REPO / "diagnostics_full" / "out"
    for f in sorted(out.glob("*.csv")):
        print(f"  {f.relative_to(REPO)}")
    print()
    print("Final root cause: diagnostics_full/10_FINAL_ROOT_CAUSE.md")
    print("Executive summary: diagnostics_full/00_EXEC_SUMMARY.md")

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
