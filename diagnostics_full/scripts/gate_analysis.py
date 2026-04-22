#!/usr/bin/env python3
"""Phase 7 emission gate analysis."""

from __future__ import annotations

import csv
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT_DIR = REPO / "diagnostics_full" / "out"

GATES = [
    ("lif_v", "rtl/lif_tile_tmux.v:54 (hit_comb)", "Input must hash-match scan"),
    ("delay", "rtl/delay_lattice_rb.v:??", "Delay lattice taps nonzero"),
    ("reichardt", "rtl/reichardt_ds.v", "Direction detector emits ds_v"),
    ("burst", "rtl/burst_gate.v", "Burst gate opens"),
    ("pred", "rtl/ab_predictor.v", "Predictor out_valid"),
]


def parse_stage_log(path: Path) -> dict:
    stats = {}
    text = path.read_text().strip()
    for token in text.split():
        if "=" in token:
            k, v = token.split("=", 1)
            stats[k] = int(v) if v.lstrip("-").isdigit() else v
    return stats


def main() -> None:
    stage_log = OUT_DIR / "stage_activity_must.log"
    stats = parse_stage_log(stage_log)
    rows = []
    upstream = stats.get("events", 0)
    chain_order = [("lif", upstream)] + [(key, 0) for key, _, _ in GATES[1:]]
    upstream_map = {"lif": stats.get("events", 0)}
    upstream_map["delay"] = stats.get("lif", 0)
    upstream_map["reichardt"] = stats.get("delay", 0)
    upstream_map["burst"] = stats.get("reichardt", 0)
    upstream_map["pred"] = stats.get("burst", 0)
    blocker_rank = 1
    for key, loc, note in GATES:
        true_count = stats.get(key if key != "lif_v" else "lif", 0)
        upstream = upstream_map.get("lif" if key == "lif_v" else key, 0)
        false_count = upstream - true_count if upstream >= true_count else 0
        rows.append(
            {
                "gate_term": key,
                "source_location": loc,
                "observed_true_count": true_count,
                "observed_false_count": false_count,
                "blocker_rank": blocker_rank if true_count == 0 else "",
                "notes": note,
            }
        )
        if true_count == 0 and blocker_rank != "":
            blocker_rank += 1
    csv_path = OUT_DIR / "emission_gate_results.csv"
    fieldnames = [
        "gate_term",
        "source_location",
        "observed_true_count",
        "observed_false_count",
        "blocker_rank",
        "notes",
    ]
    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)
    with (OUT_DIR / "emission_gate_results.json").open("w") as fh:
        json.dump(rows, fh, indent=2)


if __name__ == "__main__":
    main()
