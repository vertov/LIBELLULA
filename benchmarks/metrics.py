"""Metric computation utilities for benchmark harness."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Iterable, List, Mapping, Sequence, Tuple
import math
import statistics

from .baselines import TrackerSample
from .scenarios import ScenarioSpec, TruthSample


@dataclass
class MetricResult:
    scenario: str
    tracker: str
    values: Dict[str, float]


def _truth_lookup(truth_map: Mapping[int, TruthSample], cycle: int) -> TruthSample | None:
    return truth_map.get(cycle)


def compute_prediction_metrics(
    samples: Sequence[TrackerSample],
    scenario: ScenarioSpec,
    dist_threshold: float = 5.0,
) -> Tuple[Dict[str, float], Dict[int, float]]:
    """Return (metrics, error_per_cycle_for_h1)."""
    horizon_errors: Dict[int, List[float]] = {h: [] for h in scenario.horizons}
    horizon_rmse: Dict[int, List[float]] = {h: [] for h in scenario.horizons}
    error_cycle_map: Dict[int, float] = {}

    for sample in samples:
        for pred in sample.predictions:
            gt_cycle = sample.cycle + pred.horizon
            truth = _truth_lookup(scenario.truth_map, gt_cycle)
            if truth is None or not truth.visible:
                continue
            err = math.hypot(pred.x - truth.x, pred.y - truth.y)
            horizon_errors[pred.horizon].append(err)
            horizon_rmse[pred.horizon].append(err * err)
            if pred.horizon == min(scenario.horizons):
                error_cycle_map[sample.cycle] = err

    metrics: Dict[str, float] = {}
    for horizon, errors in horizon_errors.items():
        if not errors:
            continue
        metrics[f"mae_h{horizon}"] = float(sum(errors) / len(errors))
        rmse = math.sqrt(sum(horizon_rmse[horizon]) / len(horizon_rmse[horizon]))
        metrics[f"rmse_h{horizon}"] = float(rmse)
    min_h = min(scenario.horizons) if scenario.horizons else 1
    metrics["prediction_count"] = len(horizon_errors.get(min_h, []))
    metrics["track_continuity"] = _track_continuity(samples)
    metrics["false_lock_rate"] = _false_lock_rate(samples, scenario, error_cycle_map, dist_threshold)
    metrics.update(_recovery_metrics(scenario, error_cycle_map, dist_threshold))
    return metrics, error_cycle_map


def _track_continuity(samples: Sequence[TrackerSample]) -> float:
    if not samples:
        return 0.0
    locked = sum(1 for s in samples if s.locked)
    return locked / len(samples)


def _false_lock_rate(
    samples: Sequence[TrackerSample],
    scenario: ScenarioSpec,
    error_cycle_map: Mapping[int, float],
    threshold: float,
) -> float:
    violations = 0
    total_locked = 0
    for sample in samples:
        if not sample.locked:
            continue
        total_locked += 1
        err = error_cycle_map.get(sample.cycle)
        if err is not None and err > threshold:
            violations += 1
    if total_locked == 0:
        return 0.0
    return violations / total_locked


def _recovery_metrics(
    scenario: ScenarioSpec,
    error_cycle_map: Mapping[int, float],
    threshold: float,
) -> Dict[str, float]:
    recoveries: List[int] = []
    for (start, end) in scenario.occlusions:
        reacquire_cycle = None
        cycle = end + 1
        while cycle <= scenario.duration_cycles:
            err = error_cycle_map.get(cycle)
            if err is not None and err <= threshold:
                reacquire_cycle = cycle
                break
            cycle += 1
        if reacquire_cycle is not None:
            recoveries.append(reacquire_cycle - end)
    if not recoveries:
        return {"recovery_cycles_mean": 0.0}
    return {
        "recovery_cycles_mean": float(sum(recoveries) / len(recoveries)),
        "recovery_cycles_max": float(max(recoveries)),
    }


def latency_statistics(latencies: Iterable[float]) -> Dict[str, float]:
    arr = [float(v) for v in latencies if v is not None]
    if not arr:
        return {"latency_mean": 0.0, "latency_p95": 0.0, "latency_p99": 0.0, "latency_max": 0.0}
    arr.sort()
    def percentile(p: float) -> float:
        idx = min(len(arr) - 1, max(0, int(math.ceil(p * len(arr) - 1))))
        return arr[idx]
    return {
        "latency_mean": float(sum(arr) / len(arr)),
        "latency_p95": percentile(0.95),
        "latency_p99": percentile(0.99),
        "latency_max": arr[-1],
    }


def compute_cost_proxy(samples: Sequence[TrackerSample]) -> float:
    cost = sum(s.compute_cost for s in samples)
    if not samples:
        return 0.0
    return cost / len(samples)


def aggregate_metrics(
    tracker_name: str,
    samples: Sequence[TrackerSample],
    scenario: ScenarioSpec,
    latency_overrides: Iterable[float] | None = None,
) -> MetricResult:
    metrics, error_cycle_map = compute_prediction_metrics(samples, scenario)
    if latency_overrides is None:
        latency_values = (s.latency_cycles for s in samples)
    else:
        latency_values = latency_overrides
    metrics.update(latency_statistics(latency_values))
    metrics["compute_cost"] = compute_cost_proxy(samples)
    return MetricResult(scenario=scenario.name, tracker=tracker_name, values=metrics)


__all__ = [
    "MetricResult",
    "aggregate_metrics",
    "compute_prediction_metrics",
    "latency_statistics",
    "compute_cost_proxy",
]
