#!/usr/bin/env python3
"""
Phase 4 must-fire runner.

Builds tb_pred_must_fire, executes it once, and captures the PHASE4_RESULT line
to confirm whether the design can emit when events are aligned to the scan hash.
"""

from __future__ import annotations

import csv
import json
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = REPO_ROOT / "diagnostics" / "out"


def run_must_fire() -> dict:
    subprocess.run(
        ["make", "-C", "sim", "build/tb_pred_must_fire"],
        cwd=REPO_ROOT,
        check=True,
    )
    proc = subprocess.run(
        ["vvp", "sim/build/tb_pred_must_fire"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    status = "FAIL"
    first_cycle = -1
    pred_count = 0
    total_cycle = -1
    for line in proc.stdout.splitlines():
        if line.startswith("PHASE4_RESULT"):
            parts = dict(token.split("=", 1) for token in line.split() if "=" in token)
            status = parts.get("status", "FAIL")
            first_cycle = int(parts.get("first_cycle", "-1"))
            pred_count = int(parts.get("pred_count", "0"))
            total_cycle = int(parts.get("total_cycle", "-1"))
            break
    return {
        "test_name": "must_fire_aligned",
        "status": status,
        "first_pred_cycle": first_cycle,
        "pred_valid_count": pred_count,
        "total_cycles": total_cycle,
        "notes": proc.stdout.strip(),
    }


def write_outputs(result: dict) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    csv_path = OUT_DIR / "must_fire_results.csv"
    json_path = OUT_DIR / "must_fire_results.json"
    fieldnames = [
        "test_name",
        "status",
        "first_pred_cycle",
        "pred_valid_count",
        "total_cycles",
        "notes",
    ]
    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerow(result)
    with json_path.open("w") as fh:
        json.dump(result, fh, indent=2)


def main() -> None:
    result = run_must_fire()
    write_outputs(result)


if __name__ == "__main__":
    main()
