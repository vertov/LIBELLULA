"""Entry point for Libellula vs baseline benchmark suite."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Sequence
import argparse
import csv
import json
import sys

if __package__ is None or __package__ == "":
    # Allow running as `python benchmarks/run_benchmarks.py`.
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from benchmarks.baselines import TrackerBase, TrackerSample, build_baselines  # type: ignore
    from benchmarks.metrics import MetricResult, aggregate_metrics  # type: ignore
    from benchmarks.scenarios import ScenarioEvent, ScenarioSpec, enumerate_scenarios  # type: ignore
    from benchmarks.libellula_runner import build_benchmark_tb, run_libellula_pipeline  # type: ignore
else:
    from .baselines import TrackerBase, TrackerSample, build_baselines
    from .metrics import MetricResult, aggregate_metrics
    from .scenarios import ScenarioEvent, ScenarioSpec, enumerate_scenarios
    from .libellula_runner import build_benchmark_tb, run_libellula_pipeline


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT_DIR = REPO_ROOT / "benchmarks" / "out"
WORK_DIR = REPO_ROOT / "benchmarks" / "work"


def events_by_cycle(events: Sequence[ScenarioEvent]) -> Dict[int, List[ScenarioEvent]]:
    grouped: Dict[int, List[ScenarioEvent]] = {}
    for evt in events:
        grouped.setdefault(evt.cycle, []).append(evt)
    return grouped


def max_cycle(events: Sequence[ScenarioEvent], scenario: ScenarioSpec) -> int:
    max_evt = max((evt.cycle for evt in events), default=0)
    return max(max_evt, scenario.duration_cycles)


def run_tracker(tracker: TrackerBase, scenario: ScenarioSpec) -> List[TrackerSample]:
    tracker.reset()
    grouped = events_by_cycle(scenario.events)
    duration = max_cycle(scenario.events, scenario) + max(scenario.horizons)
    samples: List[TrackerSample] = []
    for cycle in range(duration):
        evts = grouped.get(cycle, [])
        sample = tracker.step(cycle, evts, scenario.horizons)
        samples.append(sample)
    return samples


def score_candidate(metrics: Dict[str, float]) -> float:
    mae1 = metrics.get("mae_h1", 1e6)
    mae4 = metrics.get("mae_h4", mae1)
    mae8 = metrics.get("mae_h8", mae4)
    continuity = metrics.get("track_continuity", 0.0)
    false_lock = metrics.get("false_lock_rate", 1.0)
    latency = metrics.get("latency_mean", 10.0)
    recovery = metrics.get("recovery_cycles_mean", 5.0)
    compute_cost = metrics.get("compute_cost", 1.0)
    # Weighted sum (lower is better). We penalize instability heavily.
    return (
        mae1
        + 0.5 * mae4
        + 0.25 * mae8
        + 2.0 * false_lock
        + 0.5 * recovery
        + 0.1 * latency
        + 0.05 * compute_cost
        - 0.5 * continuity
    )


@dataclass
class ScenarioReport:
    scenario: ScenarioSpec
    metric_rows: List[MetricResult]


def generate_report_rows(reports: List[ScenarioReport], csv_path: Path, json_path: Path) -> None:
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    all_fields = {"scenario", "tracker"}
    for report in reports:
        for result in report.metric_rows:
            all_fields.update(result.values.keys())
    metric_fields = sorted(f for f in all_fields if f not in {"scenario", "tracker"})
    fieldnames = ["scenario", "tracker"] + metric_fields
    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for report in reports:
            for result in report.metric_rows:
                row = {"scenario": result.scenario, "tracker": result.tracker}
                row.update(result.values)
                writer.writerow(row)
    json_blob = {}
    for report in reports:
        scen_dict = json_blob.setdefault(report.scenario.name, {})
        for result in report.metric_rows:
            scen_dict[result.tracker] = result.values
    with json_path.open("w") as fh:
        json.dump(json_blob, fh, indent=2)


def summarize_wins(reports: List[ScenarioReport], markdown_path: Path) -> None:
    markdown_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Libellula Comparative Benchmark",
        "",
        "Assumptions:",
        "- Prediction error measured as Euclidean MAE at horizons h=1,4,8 cycles.",
        "- Libellula horizon >1 estimates extrapolated from successive predictions.",
        "- False-lock defined as being locked while error >5 px at horizon-1.",
        "- Recovery evaluated from occlusion metadata when available.",
        "- Compute-cost proxy derived from normalized per-event operations; Libellula fixed to 1.0.",
        "",
        "| Scenario | Outcome | Notes |",
        "|---|---|---|",
    ]
    for report in reports:
        scores = []
        for result in report.metric_rows:
            scores.append((score_candidate(result.values), result.tracker, result))
        scores.sort(key=lambda x: x[0])
        if not scores:
            continue
        best_score = scores[0][0]
        tied = [s for s in scores if abs(s[0] - best_score) < 1e-6]
        if len(tied) > 1:
            outcome = f"Tie: {', '.join(t[1] for t in tied)}"
        else:
            outcome = f"Win: {scores[0][1]}"
        lines.append(
            f"| {report.scenario.name} | {outcome} | lowest composite score {best_score:.3f} |"
        )
    with markdown_path.open("w") as fh:
        fh.write("\n".join(lines))


def run_suite(
    out_dir: Path,
    include_libellula: bool = True,
    iverilog_bin: str = "iverilog",
    vvp_bin: str = "vvp",
) -> List[ScenarioReport]:
    scenarios = enumerate_scenarios()
    baselines = build_baselines()
    reports: List[ScenarioReport] = []
    if include_libellula:
        build_benchmark_tb(REPO_ROOT, iverilog_bin)
    for scenario in scenarios:
        metric_rows: List[MetricResult] = []
        for tracker_name, tracker in baselines.items():
            samples = run_tracker(tracker, scenario)
            metric_rows.append(aggregate_metrics(tracker_name, samples, scenario))
        if include_libellula:
            padding = len(scenario.events) * 4 + 256
            artifacts = run_libellula_pipeline(
                repo_root=REPO_ROOT,
                scenario=scenario,
                work_dir=WORK_DIR,
                max_cycles=max_cycle(scenario.events, scenario) + padding,
                iverilog_bin=iverilog_bin,
                vvp_bin=vvp_bin,
                build=False,
            )
            metric_rows.append(
                aggregate_metrics("libellula_core", artifacts.samples, scenario)
            )
        reports.append(ScenarioReport(scenario=scenario, metric_rows=metric_rows))
    out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = out_dir / "benchmark_results.csv"
    json_path = out_dir / "benchmark_results.json"
    report_md = out_dir / "benchmark_report.md"
    generate_report_rows(reports, csv_path, json_path)
    summarize_wins(reports, report_md)
    return reports


def main() -> None:
    parser = argparse.ArgumentParser(description="Run Libellula comparative benchmark suite.")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR, help="Output directory for CSV/JSON/report.")
    parser.add_argument("--skip-libellula", action="store_true", help="Only run software baselines.")
    parser.add_argument("--iverilog", default="iverilog", help="iverilog binary path.")
    parser.add_argument("--vvp", default="vvp", help="vvp binary path.")
    args = parser.parse_args()
    run_suite(
        out_dir=args.out_dir,
        include_libellula=not args.skip_libellula,
        iverilog_bin=args.iverilog,
        vvp_bin=args.vvp,
    )


if __name__ == "__main__":
    main()
