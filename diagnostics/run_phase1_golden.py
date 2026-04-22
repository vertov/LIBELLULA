#!/usr/bin/env python3
"""
Phase 1 golden-path sweep runner.

Builds tb_pred_valid_golden once, then runs several parameter sets, capturing
pred_valid counts and writing CSV/JSON summaries under diagnostics/out/.
"""

from __future__ import annotations

import csv
import json
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SIM_DIR = REPO_ROOT / "sim"
OUT_DIR = REPO_ROOT / "diagnostics" / "out"

TESTS = [
    dict(name="GP1", event_spacing=1, event_count=64, y_wiggle=0),
    dict(name="GP2", event_spacing=2, event_count=64, y_wiggle=0),
    dict(name="GP3", event_spacing=1, event_count=128, y_wiggle=0, quiet_cycles=64),
    dict(name="GP4", event_spacing=1, event_count=64, y_wiggle=1),
]


def build_tb() -> None:
    subprocess.run(
        ["make", "-C", "sim", "build/tb_pred_valid_golden"],
        cwd=REPO_ROOT,
        check=True,
    )


def run_test(cfg: dict) -> dict:
    plusargs = [
        f"+TEST_NAME={cfg['name']}",
        f"+EVENT_SPACING={cfg.get('event_spacing', 1)}",
        f"+EVENT_COUNT={cfg.get('event_count', 64)}",
        f"+RESET_CYCLES={cfg.get('reset_cycles', 64)}",
        f"+QUIET_CYCLES={cfg.get('quiet_cycles', 32)}",
        f"+TAIL_CYCLES={cfg.get('tail_cycles', 256)}",
        f"+Y_WIGGLE={cfg.get('y_wiggle', 0)}",
        f"+POL_TOGGLE={cfg.get('pol_toggle', 0)}",
    ]
    proc = subprocess.run(
        ["vvp", "sim/build/tb_pred_valid_golden", *plusargs],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    pred_count = 0
    first_cycle = -1
    total_cycle = -1
    for line in proc.stdout.splitlines():
        if line.startswith("PHASE1_RESULT"):
            parts = dict(
                token.split("=", 1) for token in line.split() if "=" in token
            )
            pred_count = int(parts.get("pred_count", "0"))
            first_cycle = int(parts.get("first_cycle", "-1"))
            total_cycle = int(parts.get("total_cycle", "-1"))
            break
    notes = "no PHASE1_RESULT line" if total_cycle < 0 else ""
    pass_fail = "PASS" if pred_count > 0 else "FAIL"
    if pred_count == 0:
        notes = (notes + " pred_valid never asserted").strip()
    return {
        "test_name": cfg["name"],
        "simulator": "vvp",
        "seed": "deterministic",
        "target_speed": 1,
        "event_rate_cycles": cfg.get("event_spacing", 1),
        "event_count": cfg.get("event_count", 64),
        "reset_cycles": cfg.get("reset_cycles", 64),
        "warmup_cycles": cfg.get("quiet_cycles", 32),
        "total_cycles": total_cycle,
        "pred_valid_count": pred_count,
        "first_pred_cycle": first_cycle,
        "pass_fail": pass_fail,
        "notes": notes.strip(),
    }


def write_outputs(results: list[dict]) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    csv_path = OUT_DIR / "golden_path_results.csv"
    json_path = OUT_DIR / "golden_path_results.json"
    fieldnames = [
        "test_name",
        "simulator",
        "seed",
        "target_speed",
        "event_rate_cycles",
        "event_count",
        "reset_cycles",
        "warmup_cycles",
        "total_cycles",
        "pred_valid_count",
        "first_pred_cycle",
        "pass_fail",
        "notes",
    ]
    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in results:
            writer.writerow(row)
    with json_path.open("w") as fh:
        json.dump(results, fh, indent=2)


def main() -> None:
    build_tb()
    results = [run_test(cfg) for cfg in TESTS]
    write_outputs(results)


if __name__ == "__main__":
    main()
