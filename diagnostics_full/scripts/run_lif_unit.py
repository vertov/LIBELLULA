#!/usr/bin/env python3
"""Phase 2 LIF unit analysis."""

from __future__ import annotations

import csv
import json
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "diagnostics_full" / "out"


def build() -> None:
    subprocess.run(
        ["make", "-C", "sim", "build/tb_lif_unit_diag"],
        cwd=REPO,
        check=True,
    )


def run_case(name: str, scan_mode: int, hit_count: int, hit_spacing: int) -> dict:
    cmd = [
        "vvp",
        "sim/build/tb_lif_unit_diag",
        f"+BENCH_NAME={name}",
        f"+TARGET_ADDR=5",
        f"+HIT_COUNT={hit_count}",
        f"+HIT_SPACING={hit_spacing}",
        f"+SCAN_MODE={scan_mode}",
    ]
    proc = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, check=True)
    result_line = ""
    for line in proc.stdout.splitlines():
        if line.startswith("LIF_RESULT"):
            result_line = line
            break
    parts = dict(token.split("=", 1) for token in result_line.split() if "=" in token)
    spiked = parts.get("spiked", "0") == "1"
    return {
        "bench_name": name,
        "target_cell": int(parts.get("target", "5")),
        "legal_stimulus_description": "hash-aligned hits",
        "hit_count": hit_count,
        "hit_spacing": hit_spacing,
        "reset_cycles": 64,
        "threshold_param": int(parts.get("thresh", "16")),
        "leak_param": int(parts.get("leak_shift", "2")),
        "scan_condition": "hold" if scan_mode == 0 else "free-run",
        "accumulator_peak": int(parts.get("peak", "0")),
        "spiked": int(parts.get("spiked", "0")),
        "first_spike_cycle": int(parts.get("first_spike", "-1")),
        "notes": result_line,
    }


def main() -> None:
    build()
    results = [
        run_case("lif_hold", scan_mode=0, hit_count=32, hit_spacing=0),
        run_case("lif_free_run", scan_mode=1, hit_count=64, hit_spacing=0),
    ]
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    csv_path = OUT_DIR / "lif_unit_results.csv"
    fieldnames = [
        "bench_name",
        "target_cell",
        "legal_stimulus_description",
        "hit_count",
        "hit_spacing",
        "reset_cycles",
        "threshold_param",
        "leak_param",
        "scan_condition",
        "accumulator_peak",
        "spiked",
        "first_spike_cycle",
        "notes",
    ]
    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in results:
            writer.writerow(row)
    with (OUT_DIR / "lif_unit_results.json").open("w") as fh:
        json.dump(results, fh, indent=2)


if __name__ == "__main__":
    main()
