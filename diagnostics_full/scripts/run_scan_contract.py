#!/usr/bin/env python3
"""Phase 3 scan/hash contract analysis."""

from __future__ import annotations

import csv
import json
import os
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "diagnostics_full" / "out"

MODES = [
    (0, "unscheduled"),
    (1, "wait_for_match"),
    (2, "hold_until_match"),
    (3, "retry_three_times"),
]


def build() -> None:
    env = {"IVERILOG": "iverilog -DLIBELLULA_STAGE_DIAG"}
    subprocess.run(
        ["make", "-C", "sim", "build/tb_scan_hash_diag"],
        cwd=REPO,
        check=True,
        env={**os.environ, **env},
    )


def parse_stage(path: Path) -> dict:
    text = path.read_text().strip()
    stats = {}
    for token in text.split():
        if "=" in token:
            k, v = token.split("=", 1)
            stats[k] = int(v) if v.lstrip("-").isdigit() else v
    return stats


def run_mode(mode: int, name: str) -> dict:
    stage_log = OUT_DIR / f"stage_scan_{mode}.log"
    if stage_log.exists():
        stage_log.unlink()
    cmd = [
        "vvp",
        "sim/build/tb_scan_hash_diag",
        f"+STIM_MODE={mode}",
        f"+BENCH_NAME={name}",
        f"+STAGE_OUT={stage_log.relative_to(REPO)}",
    ]
    subprocess.run(cmd, cwd=REPO, check=True)
    stats = parse_stage(stage_log)
    events = stats.get("events", 0)
    accepted = stats.get("lif", 0)
    downstream = max(stats.get(k, 0) for k in ("delay", "reichardt", "burst", "pred"))
    return {
        "bench_name": name,
        "stimulus_mode": name,
        "event_count": events,
        "accepted_count": accepted,
        "acceptance_ratio": 0 if events == 0 else accepted / events,
        "lif_nonzero": int(accepted > 0),
        "downstream_nonzero": int(downstream > 0),
        "pred_valid_count": stats.get("pred", 0),
        "notes": stage_log.read_text().strip(),
    }


def main() -> None:
    build()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    results = [run_mode(mode, name) for mode, name in MODES]
    csv_path = OUT_DIR / "scan_hash_results.csv"
    fieldnames = [
        "bench_name",
        "stimulus_mode",
        "event_count",
        "accepted_count",
        "acceptance_ratio",
        "lif_nonzero",
        "downstream_nonzero",
        "pred_valid_count",
        "notes",
    ]
    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in results:
            writer.writerow(row)
    with (OUT_DIR / "scan_hash_results.json").open("w") as fh:
        json.dump(results, fh, indent=2)


if __name__ == "__main__":
    main()
