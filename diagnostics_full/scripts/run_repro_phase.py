#!/usr/bin/env python3
"""Phase 1 reproduction runs."""

from __future__ import annotations

import csv
import json
import os
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "diagnostics_full" / "out"


def build(bench: str) -> None:
    env = {"IVERILOG": "iverilog -DLIBELLULA_STAGE_DIAG"}
    subprocess.run(
        ["make", "-C", "sim", f"build/{bench}"],
        cwd=REPO,
        check=True,
        env={**os.environ, **env},
    )


def parse_stage_log(path: Path) -> dict:
    text = path.read_text().strip()
    stats = {}
    for token in text.split():
        if "=" in token:
            k, v = token.split("=", 1)
            try:
                stats[k] = int(v)
            except ValueError:
                stats[k] = v
    return stats


def run_golden() -> dict:
    build("tb_pred_valid_golden")
    stage_log = OUT_DIR / "stage_golden.log"
    if stage_log.exists():
        stage_log.unlink()
    cmd = [
        "vvp",
        "sim/build/tb_pred_valid_golden",
        "+TEST_NAME=full_gp",
        "+EVENT_SPACING=1",
        "+EVENT_COUNT=64",
        "+RESET_CYCLES=64",
        "+QUIET_CYCLES=32",
        f"+STAGE_OUT={stage_log.relative_to(REPO)}",
    ]
    proc = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    pred_count = 0
    first_pred = -1
    for line in proc.stdout.splitlines():
        if line.startswith("PHASE1_RESULT"):
            parts = dict(token.split("=", 1) for token in line.split() if "=" in token)
            pred_count = int(parts.get("pred_count", "0"))
            first_pred = int(parts.get("first_cycle", "-1"))
            total_cycle = int(parts.get("total_cycle", "-1"))
            break
    stats = parse_stage_log(stage_log)
    return {
        "test_name": "golden_unscheduled",
        "command": " ".join(cmd),
        "simulator": "vvp",
        "reset_cycles": 64,
        "warmup_cycles": 32,
        "total_cycles": total_cycle,
        "event_pattern": "linear monotonic unscheduled",
        "pred_valid_count": pred_count,
        "first_pred_cycle": first_pred,
        "first_nonzero_lif_cycle": stats.get("first_lif", -1),
        "first_nonzero_delay_cycle": stats.get("first_delay", -1),
        "first_nonzero_reichardt_cycle": stats.get("first_reichardt", -1),
        "first_nonzero_burst_cycle": stats.get("first_burst", -1),
        "pass_fail": "FAIL" if pred_count == 0 else "PASS",
        "notes": stage_log.read_text().strip(),
    }


def run_must_fire() -> dict:
    build("tb_pred_must_fire")
    stage_log = OUT_DIR / "stage_must_fire.log"
    if stage_log.exists():
        stage_log.unlink()
    cmd = [
        "vvp",
        "sim/build/tb_pred_must_fire",
        "+X_STEP=1",
        f"+STAGE_OUT={stage_log.relative_to(REPO)}",
    ]
    proc = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    pred_count = 0
    first_pred = -1
    total_cycle = -1
    for line in proc.stdout.splitlines():
        if line.startswith("PHASE4_RESULT"):
            parts = dict(token.split("=", 1) for token in line.split() if "=" in token)
            pred_count = int(parts.get("pred_count", "0"))
            first_pred = int(parts.get("first_cycle", "-1"))
            total_cycle = int(parts.get("total_cycle", "-1"))
            break
    stats = parse_stage_log(stage_log)
    return {
        "test_name": "must_fire_aligned",
        "command": " ".join(cmd),
        "simulator": "vvp",
        "reset_cycles": 128,
        "warmup_cycles": 64,
        "total_cycles": total_cycle,
        "event_pattern": "hash-aligned sequential hits",
        "pred_valid_count": pred_count,
        "first_pred_cycle": first_pred,
        "first_nonzero_lif_cycle": stats.get("first_lif", -1),
        "first_nonzero_delay_cycle": stats.get("first_delay", -1),
        "first_nonzero_reichardt_cycle": stats.get("first_reichardt", -1),
        "first_nonzero_burst_cycle": stats.get("first_burst", -1),
        "pass_fail": "FAIL" if pred_count == 0 else "PASS",
        "notes": stage_log.read_text().strip(),
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    results = [run_golden(), run_must_fire()]
    csv_path = OUT_DIR / "repro_runs.csv"
    fieldnames = [
        "test_name",
        "command",
        "simulator",
        "reset_cycles",
        "warmup_cycles",
        "total_cycles",
        "event_pattern",
        "pred_valid_count",
        "first_pred_cycle",
        "first_nonzero_lif_cycle",
        "first_nonzero_delay_cycle",
        "first_nonzero_reichardt_cycle",
        "first_nonzero_burst_cycle",
        "pass_fail",
        "notes",
    ]
    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in results:
            writer.writerow(row)
    with (OUT_DIR / "repro_runs.json").open("w") as fh:
        json.dump(results, fh, indent=2)


if __name__ == "__main__":
    main()
