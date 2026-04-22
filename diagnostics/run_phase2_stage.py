#!/usr/bin/env python3
"""
Phase 2 stage instrumentation runner.

Builds tb_pred_valid_golden with LIBELLULA_STAGE_DIAG enabled, runs a single
stimulus, and parses the stage counter log emitted by libellula_top.
"""

from __future__ import annotations

import csv
import json
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = REPO_ROOT / "diagnostics" / "out"


def build_with_diag() -> None:
    subprocess.run(
        ["make", "-C", "sim", "build/tb_pred_valid_golden"],
        cwd=REPO_ROOT,
        check=True,
        env={**dict(), "IVERILOG": "iverilog -DLIBELLULA_STAGE_DIAG"},
    )


def run_test(stage_log: Path) -> dict:
    if stage_log.exists():
        stage_log.unlink()
    stage_rel = stage_log.relative_to(REPO_ROOT)
    plusargs = [
        "+TEST_NAME=GP1_STAGE",
        "+EVENT_SPACING=1",
        "+EVENT_COUNT=64",
        "+RESET_CYCLES=64",
        "+QUIET_CYCLES=32",
        f"+STAGE_OUT={stage_rel}",
    ]
    subprocess.run(
        ["vvp", "sim/build/tb_pred_valid_golden", *plusargs],
        cwd=REPO_ROOT,
        check=True,
    )
    text = stage_log.read_text().strip()
    stats = {}
    for token in text.split():
        if "=" in token:
            k, v = token.split("=", 1)
            stats[k] = int(v)
    order = [
        ("events", "input stage (aer_rx)"),
        ("lif", "LIF spikes"),
        ("delay", "delay lattice outputs"),
        ("reichardt", "direction detector"),
        ("burst", "burst gate"),
        ("pred", "predictor"),
    ]
    first_dead = "none"
    suspected = ""
    for key, desc in order:
        if stats.get(key, 0) == 0:
            first_dead = desc
            suspected = key
            break
    return {
        "test_name": "GP1_STAGE",
        "events_seen": stats.get("events", 0),
        "events_accepted": stats.get("lif", 0),
        "stage1_activity": stats.get("lif", 0),
        "stage2_activity": stats.get("delay", 0),
        "stage3_activity": stats.get("reichardt", 0),
        "stage4_activity": stats.get("burst", 0),
        "stage5_activity": stats.get("pred", 0),
        "pred_valid_count": stats.get("pred", 0),
        "first_dead_stage": first_dead,
        "suspected_blocker": suspected,
        "notes": text,
    }


def write_outputs(result: dict) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    csv_path = OUT_DIR / "stage_counters.csv"
    json_path = OUT_DIR / "stage_counters.json"
    fieldnames = [
        "test_name",
        "events_seen",
        "events_accepted",
        "stage1_activity",
        "stage2_activity",
        "stage3_activity",
        "stage4_activity",
        "stage5_activity",
        "pred_valid_count",
        "first_dead_stage",
        "suspected_blocker",
        "notes",
    ]
    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerow(result)
    with json_path.open("w") as fh:
        json.dump(result, fh, indent=2)


def main() -> None:
    stage_log = OUT_DIR / "stage_GP1.log"
    build_with_diag()
    result = run_test(stage_log)
    write_outputs(result)


if __name__ == "__main__":
    main()
