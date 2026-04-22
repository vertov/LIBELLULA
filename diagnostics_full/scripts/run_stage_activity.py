#!/usr/bin/env python3
"""Phase 4 stage activity capture."""

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


def stage_row(test_name: str, stats: dict) -> dict:
    stages = [
        ("events", "AER input"),
        ("lif", "LIF spikes"),
        ("delay", "Delay lattice"),
        ("reichardt", "Reichardt"),
        ("burst", "Burst gate"),
        ("pred", "Predictor"),
    ]
    earliest = "none"
    for key, label in stages[1:]:
        if stats.get(key, 0) == 0:
            earliest = label
            break
    return {
        "run_id": test_name,
        "events_presented": stats.get("events", 0),
        "events_accepted": stats.get("lif", 0),
        "lif_accumulator_nonzero_count": stats.get("lif", 0),
        "lif_spike_count": stats.get("lif", 0),
        "delay_activity_count": stats.get("delay", 0),
        "reichardt_activity_count": stats.get("reichardt", 0),
        "burst_open_count": stats.get("burst", 0),
        "predictor_candidate_count": stats.get("pred", 0),
        "pred_valid_count": stats.get("pred", 0),
        "earliest_dead_stage": earliest,
        "notes": stats.get("raw", ""),
    }


def parse_stage(path: Path) -> dict:
    text = path.read_text().strip()
    stats = {"raw": text}
    for token in text.split():
        if "=" in token:
            k, v = token.split("=", 1)
            stats[k] = int(v) if v.lstrip("-").isdigit() else v
    return stats


def run_tests() -> list[dict]:
    rows = []
    # golden unscheduled
    build("tb_pred_valid_golden")
    stage_golden = OUT_DIR / "stage_activity_golden.log"
    subprocess.run(
        [
            "vvp",
            "sim/build/tb_pred_valid_golden",
            "+TEST_NAME=stage_gp",
            f"+STAGE_OUT={stage_golden.relative_to(REPO)}",
        ],
        cwd=REPO,
        check=True,
    )
    rows.append(stage_row("golden_unscheduled", parse_stage(stage_golden)))
    # must-fire aligned
    build("tb_pred_must_fire")
    stage_must = OUT_DIR / "stage_activity_must.log"
    subprocess.run(
        [
            "vvp",
            "sim/build/tb_pred_must_fire",
            f"+STAGE_OUT={stage_must.relative_to(REPO)}",
        ],
        cwd=REPO,
        check=False,
    )
    rows.append(stage_row("must_fire_aligned", parse_stage(stage_must)))
    return rows


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    rows = run_tests()
    csv_path = OUT_DIR / "stage_activity.csv"
    fieldnames = [
        "run_id",
        "events_presented",
        "events_accepted",
        "lif_accumulator_nonzero_count",
        "lif_spike_count",
        "delay_activity_count",
        "reichardt_activity_count",
        "burst_open_count",
        "predictor_candidate_count",
        "pred_valid_count",
        "earliest_dead_stage",
        "notes",
    ]
    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
    with (OUT_DIR / "stage_activity.json").open("w") as fh:
        json.dump(rows, fh, indent=2)


if __name__ == "__main__":
    main()
