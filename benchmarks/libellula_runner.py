"""Utilities to drive the Libellula RTL benchmark driver."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Sequence
import csv
import subprocess

from .baselines import TrackerPrediction, TrackerSample
from .scenarios import ScenarioEvent, ScenarioSpec


@dataclass
class LibellulaRunArtifacts:
    event_csv: Path
    prediction_csv: Path
    samples: List[TrackerSample]


def ensure_dir(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def write_event_file(events: Sequence[ScenarioEvent], path: Path, addr_width: int = 8) -> int:
    ensure_dir(path)
    scan_period = 1 << addr_width
    period_mask = scan_period - 1
    last_sim_cycle = 0
    with path.open("w", newline="") as fh:
        fh.write(f"{len(events)}\n")
        writer = csv.writer(fh)
        for evt in events:
            scenario_cycle = int(evt.cycle)
            x = int(round(evt.x))
            y = int(round(evt.y))
            hashed = (x ^ y) & period_mask
            desired = max(last_sim_cycle + 1, scenario_cycle)
            base = (desired // scan_period) * scan_period
            sim_cycle = base + hashed
            if sim_cycle < desired:
                sim_cycle += scan_period
            last_sim_cycle = sim_cycle
            writer.writerow([sim_cycle, scenario_cycle, x, y, evt.polarity])
    return last_sim_cycle


def build_benchmark_tb(repo_root: Path, iverilog: str = "iverilog") -> None:
    subprocess.run(
        [
            "make",
            "-C",
            "sim",
            f"IVERILOG={iverilog}",
            "build/tb_benchmark_driver",
        ],
        cwd=repo_root,
        check=True,
    )


def _relativize(path: Path, base: Path) -> str:
    try:
        return str(path.relative_to(base))
    except ValueError:
        return str(path)


def run_libellula_sim(
    repo_root: Path,
    event_csv: Path,
    prediction_csv: Path,
    max_cycles: int,
    flush_cycles: int = 128,
    vvp_bin: str = "vvp",
) -> None:
    ensure_dir(prediction_csv)
    event_arg = _relativize(event_csv, repo_root)
    pred_arg = _relativize(prediction_csv, repo_root)
    subprocess.run(
        [
            vvp_bin,
            "sim/build/tb_benchmark_driver",
            f"+EVENTS={event_arg}",
            f"+PRED_OUT={pred_arg}",
            f"+MAX_CYCLES={max_cycles}",
            f"+FLUSH={flush_cycles}",
        ],
        cwd=repo_root,
        check=True,
    )


def parse_predictions(pred_csv: Path, scenario: ScenarioSpec) -> List[TrackerSample]:
    samples: List[TrackerSample] = []
    previous_cycle = None
    previous_x = None
    previous_y = None
    with pred_csv.open() as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            sim_cycle = int(row["sim_cycle"])
            scenario_cycle = int(row.get("scenario_cycle", sim_cycle))
            x_hat = float(row["x_hat"])
            y_hat = float(row["y_hat"])
            conf = int(row["conf"])
            latency = int(row.get("latency_cycles", "5")) if row.get("latency_cycles") else 5
            predictions: List[TrackerPrediction] = []
            vx = 0.0
            vy = 0.0
            if previous_cycle is not None and scenario_cycle > previous_cycle:
                dt = max(1, scenario_cycle - previous_cycle)
                vx = (x_hat - previous_x) / dt
                vy = (y_hat - previous_y) / dt
            for horizon in scenario.horizons:
                preds_x = x_hat + vx * horizon
                preds_y = y_hat + vy * horizon
                predictions.append(
                    TrackerPrediction(
                        horizon=horizon,
                        x=preds_x,
                        y=preds_y,
                        locked=(conf > 0),
                    )
                )
            samples.append(
                TrackerSample(
                    cycle=scenario_cycle,
                    predictions=predictions,
                    latency_cycles=latency if latency >= 0 else 5,
                    compute_cost=1.0,
                    locked=(conf > 0),
                )
            )
            previous_cycle = scenario_cycle
            previous_x = x_hat
            previous_y = y_hat
    return samples


def run_libellula_pipeline(
    repo_root: Path,
    scenario: ScenarioSpec,
    work_dir: Path,
    max_cycles: int,
    iverilog_bin: str = "iverilog",
    vvp_bin: str = "vvp",
    build: bool = False,
) -> LibellulaRunArtifacts:
    work_dir.mkdir(parents=True, exist_ok=True)
    event_csv = work_dir / f"{scenario.name}_events.csv"
    prediction_csv = work_dir / f"{scenario.name}_libellula_predictions.csv"
    last_sim_cycle = write_event_file(scenario.events, event_csv)
    if build:
        build_benchmark_tb(repo_root, iverilog_bin)
    run_libellula_sim(
        repo_root,
        event_csv=event_csv,
        prediction_csv=prediction_csv,
        max_cycles=max(max_cycles, last_sim_cycle + 512),
        vvp_bin=vvp_bin,
    )
    samples = parse_predictions(prediction_csv, scenario)
    return LibellulaRunArtifacts(event_csv=event_csv, prediction_csv=prediction_csv, samples=samples)


__all__ = [
    "LibellulaRunArtifacts",
    "run_libellula_pipeline",
    "write_event_file",
    "parse_predictions",
    "build_benchmark_tb",
    "run_libellula_sim",
]
