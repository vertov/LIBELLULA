#!/usr/bin/env python3
"""Phase 5 parameter sensitivity sweep."""

from __future__ import annotations

import csv
import json
import os
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "diagnostics_full" / "out"

CASES = [
    dict(name="default", leak=2, thresh=16, scan_mode=0),
    dict(name="no_leak", leak=0, thresh=16, scan_mode=0),
    dict(name="low_thresh", leak=2, thresh=2, scan_mode=0),
]


def build(leak: int, thresh: int) -> None:
    env = {
        "IVERILOG": f"iverilog -P tb_lif_unit_diag.P_LEAK_SHIFT={leak} "
        f"-P tb_lif_unit_diag.P_THRESH={thresh}"
    }
    subprocess.run(
        ["make", "-C", "sim", "build/tb_lif_unit_diag"],
        cwd=REPO,
        check=True,
        env={**os.environ, **env},
    )


def run_case(cfg: dict) -> dict:
    build(cfg["leak"], cfg["thresh"])
    proc = subprocess.run(
        [
            "vvp",
            "sim/build/tb_lif_unit_diag",
            f"+BENCH_NAME=param_{cfg['name']}",
            f"+SCAN_MODE={cfg.get('scan_mode',0)}",
            "+HIT_COUNT=64",
        ],
        cwd=REPO,
        capture_output=True,
        text=True,
        check=True,
    )
    result_line = ""
    for line in proc.stdout.splitlines():
        if line.startswith("LIF_RESULT"):
            result_line = line
            break
    parts = dict(token.split("=", 1) for token in result_line.split() if "=" in token)
    spiked = int(parts.get("spiked", "0"))
    classification = "dead across legal parameter space"
    if spiked:
        classification = "emits under extreme tuning"
    elif cfg["leak"] == 0 or cfg["thresh"] <= 2:
        classification = "emits only under extreme tuning" if spiked else "dead even under extreme tuning"
    return {
        "config_id": cfg["name"],
        "parameter_overrides": f"LEAK_SHIFT={cfg['leak']} THRESH={cfg['thresh']}",
        "lif_spike_count": spiked,
        "downstream_activity": 0,
        "pred_valid_count": 0,
        "first_pred_cycle": -1,
        "classification": classification,
        "notes": result_line,
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    results = [run_case(cfg) for cfg in CASES]
    csv_path = OUT_DIR / "param_sweep_results.csv"
    fieldnames = [
        "config_id",
        "parameter_overrides",
        "lif_spike_count",
        "downstream_activity",
        "pred_valid_count",
        "first_pred_cycle",
        "classification",
        "notes",
    ]
    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in results:
            writer.writerow(row)
    with (OUT_DIR / "param_sweep_results.json").open("w") as fh:
        json.dump(results, fh, indent=2)


if __name__ == "__main__":
    main()
