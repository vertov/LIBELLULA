#!/usr/bin/env python3
"""Phase 6 internal invariant checks."""

from __future__ import annotations

import csv
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "diagnostics_full" / "out"


def load_lif_results() -> dict:
    lif_csv = OUT_DIR / "lif_unit_results.csv"
    data = {}
    with lif_csv.open() as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            data[row["bench_name"]] = row
    return data


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    lif = load_lif_results()
    invariants = []
    # Invariant: accumulator limit must exceed threshold to allow spikes
    peak = int(lif["lif_hold"]["accumulator_peak"])
    thresh = int(lif["lif_hold"]["threshold_param"])
    invariants.append(
        {
            "invariant_name": "lif_accumulator_can_reach_threshold",
            "pass_fail": "FAIL" if peak < thresh else "PASS",
            "failing_signal_or_path": "lif_tile_tmux.state_mem",
            "evidence": f"peak={peak} threshold={thresh} (lif_hold)",
            "suspected_effect": "Neuron never spikes even under continuous hits",
        }
    )
    # Invariant: accumulator decays to zero between sparse hits
    final_state = int(lif["lif_free_run"]["notes"].split("final_state=")[1].split()[0])
    invariants.append(
        {
            "invariant_name": "lif_state_stable_between_scans",
            "pass_fail": "PASS" if final_state == 0 else "FAIL",
            "failing_signal_or_path": "lif_tile_tmux.state_mem (free_run)",
            "evidence": f"final_state={final_state} after free-run cycle",
            "suspected_effect": "State decays to zero before next visit",
        }
    )
    csv_path = OUT_DIR / "invariant_results.csv"
    fieldnames = [
        "invariant_name",
        "pass_fail",
        "failing_signal_or_path",
        "evidence",
        "suspected_effect",
    ]
    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in invariants:
            writer.writerow(row)
    with (OUT_DIR / "invariant_results.json").open("w") as fh:
        json.dump(invariants, fh, indent=2)


if __name__ == "__main__":
    main()
