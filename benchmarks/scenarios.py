"""Synthetic scenarios for benchmarking Libellula against baselines."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Dict, Iterable, List, Sequence, Tuple
import math
import random


# All timings expressed in Libellula clock cycles (10 ns @ 100 MHz default in benches).
DEFAULT_DT_CYCLES = 1
DEFAULT_HORIZONS = (1, 4, 8)  # 1-cycle (~10 ns) look-ahead up to ~80 ns.


@dataclass(frozen=True)
class ScenarioEvent:
    cycle: int
    x: float
    y: float
    polarity: int = 0
    label: str = "target"  # target | distractor | noise
    target_id: int | None = 0
    visible: bool = True


@dataclass(frozen=True)
class TruthSample:
    cycle: int
    x: float
    y: float
    target_id: int = 0
    visible: bool = True


@dataclass
class ScenarioSpec:
    name: str
    description: str
    events: List[ScenarioEvent]
    truth_map: Dict[int, TruthSample]
    dt_cycles: int = DEFAULT_DT_CYCLES
    horizons: Sequence[int] = DEFAULT_HORIZONS
    occlusions: List[Tuple[int, int]] = field(default_factory=list)
    distractor_windows: List[Tuple[int, int]] = field(default_factory=list)
    assumption_notes: List[str] = field(default_factory=list)
    metadata: Dict[str, float] = field(default_factory=dict)

    @property
    def duration_cycles(self) -> int:
        if not self.truth_map:
            return 0
        return max(self.truth_map) + 1

    def truth_at(self, cycle: int) -> TruthSample | None:
        return self.truth_map.get(cycle)


def _noise(rng: random.Random, sigma: float) -> float:
    return rng.gauss(0.0, sigma)


def _build_truth(
    steps: int,
    path_fn: Callable[[int, float, float], Tuple[float, float]],
    start_x: float,
    start_y: float,
    visible_fn: Callable[[int], bool] | None = None,
    target_id: int = 0,
) -> Dict[int, TruthSample]:
    truth: Dict[int, TruthSample] = {}
    x = start_x
    y = start_y
    for cycle in range(steps):
        x, y = path_fn(cycle, x, y)
        vis = True if visible_fn is None else visible_fn(cycle)
        truth[cycle] = TruthSample(cycle=cycle, x=x, y=y, target_id=target_id, visible=vis)
    return truth


def _events_from_truth(
    truth: Dict[int, TruthSample],
    rng: random.Random,
    meas_sigma: float,
    drop_prob_fn: Callable[[int], float] | None = None,
    label: str = "target",
    target_id: int | None = 0,
) -> Iterable[ScenarioEvent]:
    for cycle in sorted(truth):
        sample = truth[cycle]
        if not sample.visible:
            continue
        drop_prob = 0.0 if drop_prob_fn is None else drop_prob_fn(cycle)
        if rng.random() < drop_prob:
            continue
        yield ScenarioEvent(
            cycle=cycle,
            x=sample.x + _noise(rng, meas_sigma),
            y=sample.y + _noise(rng, meas_sigma),
            label=label,
            target_id=target_id,
        )


def _merge_events(*event_iters: Iterable[ScenarioEvent]) -> List[ScenarioEvent]:
    events: List[ScenarioEvent] = []
    for it in event_iters:
        events.extend(list(it))
    events.sort(key=lambda e: (e.cycle, 0 if e.label == "target" else 1))
    return events


def scenario_linear_motion() -> ScenarioSpec:
    rng = random.Random(7)
    steps = 240

    def path(_: int, x: float, y: float) -> Tuple[float, float]:
        return x + 0.9, y + 0.45

    truth = _build_truth(steps, path, 32.0, 40.0)
    events = list(_events_from_truth(truth, rng, meas_sigma=0.25))
    return ScenarioSpec(
        name="linear_motion",
        description="Single pursuer target cruising at constant velocity.",
        events=events,
        truth_map=truth,
        assumption_notes=[
            "Single target with mild gaussian measurement noise.",
            "Truth sampled every Libellula cycle (10 ns).",
        ],
    )


def scenario_abrupt_acceleration() -> ScenarioSpec:
    rng = random.Random(13)
    steps = 260

    def path(cycle: int, x: float, y: float) -> Tuple[float, float]:
        if cycle < 80:
            vx, vy = 0.5, -0.2
        elif cycle < 140:
            vx, vy = 1.5, -0.15
        else:
            vx = 0.4 + 0.02 * math.sin(0.05 * cycle)
            vy = 0.3
        return x + vx, y + vy

    truth = _build_truth(steps, path, 20.0, 52.0)

    def drop_prob(cycle: int) -> float:
        return 0.4 if 90 <= cycle <= 110 else 0.05

    events = list(_events_from_truth(truth, rng, meas_sigma=0.35, drop_prob_fn=drop_prob))
    return ScenarioSpec(
        name="abrupt_acceleration",
        description="Target sharply accelerates and briefly becomes measurement sparse.",
        events=events,
        truth_map=truth,
        assumption_notes=[
            "Acceleration spike occurs between cycles 80-140.",
            "Measurements may drop with 40% probability between cycles 90-110.",
        ],
    )


def scenario_distractor_crossing() -> ScenarioSpec:
    rng = random.Random(19)
    steps = 280

    def target_path(_: int, x: float, y: float) -> Tuple[float, float]:
        return x + 0.8, y + 0.1

    def distractor_path(_: int, x: float, y: float) -> Tuple[float, float]:
        return x - 1.1, y + 0.05

    truth_target = _build_truth(steps, target_path, 16.0, 20.0)
    truth_distractor = _build_truth(steps, distractor_path, 200.0, 22.0, target_id=1)

    events_target = _events_from_truth(truth_target, rng, meas_sigma=0.2)
    events_distractor = _events_from_truth(truth_distractor, rng, meas_sigma=0.2, label="distractor", target_id=1)
    events = _merge_events(events_target, events_distractor)
    cross_window = (120, 170)
    return ScenarioSpec(
        name="distractor_crossings",
        description="Primary target crosses a distractor with overlapping measurement clusters.",
        events=events,
        truth_map=truth_target,
        distractor_windows=[cross_window],
        assumption_notes=[
            "Distractor is target_id=1 traveling opposite direction.",
            f"Danger window cycles {cross_window[0]}-{cross_window[1]} where centroids intersect.",
        ],
    )


def scenario_partial_occlusion() -> ScenarioSpec:
    rng = random.Random(23)
    steps = 260

    def visible_fn(cycle: int) -> bool:
        return not (100 <= cycle <= 140)

    def path(_: int, x: float, y: float) -> Tuple[float, float]:
        return x + 0.65, y + 0.0

    truth = _build_truth(steps, path, 40.0, 35.0, visible_fn=visible_fn)
    events = list(_events_from_truth(truth, rng, meas_sigma=0.25))
    occlusion = (100, 140)
    return ScenarioSpec(
        name="partial_occlusion",
        description="Target disappears for 40 cycles then returns with slight offset.",
        events=events,
        truth_map=truth,
        occlusions=[occlusion],
        assumption_notes=[
            f"Occlusion interval cycles {occlusion[0]}-{occlusion[1]} inclusive.",
            "Ground truth continues to move despite missing measurements.",
        ],
    )


def scenario_noise_bursts() -> ScenarioSpec:
    rng = random.Random(29)
    steps = 220

    def path(_: int, x: float, y: float) -> Tuple[float, float]:
        return x + 0.55, y + 0.4 * math.sin(0.02 * x)

    truth = _build_truth(steps, path, 28.0, 24.0)
    events_target = _events_from_truth(truth, rng, meas_sigma=0.3)

    noise_events: List[ScenarioEvent] = []
    for cycle in range(steps):
        if 70 <= cycle <= 90 or 150 <= cycle <= 165:
            if rng.random() < 0.8:
                noise_events.append(
                    ScenarioEvent(
                        cycle=cycle,
                        x= rng.uniform(0, 256),
                        y= rng.uniform(0, 256),
                        label="noise",
                        target_id=None,
                        visible=False,
                    )
                )
    events = _merge_events(events_target, noise_events)
    return ScenarioSpec(
        name="noise_bursts",
        description="Target amidst high-rate noise bursts that can tempt false locks.",
        events=events,
        truth_map=truth,
        assumption_notes=[
            "Noise bursts occur cycles 70-90 and 150-165 with uniform spatial clutter.",
            "Noise events flagged with label=noise.",
        ],
        metadata={"noise_density": 0.8},
    )


def scenario_latency_stress() -> ScenarioSpec:
    rng = random.Random(31)
    steps = 320

    def path(_: int, x: float, y: float) -> Tuple[float, float]:
        return x + 1.4, y + 0.05 * math.sin(0.1 * x)

    truth = _build_truth(steps, path, 18.0, 45.0)
    events_target: List[ScenarioEvent] = []
    for cycle in range(steps):
        sample = truth[cycle]
        burst = 4 if (120 <= cycle <= 180) else 2
        for _ in range(burst):
            events_target.append(
                ScenarioEvent(
                    cycle=cycle,
                    x=sample.x + _noise(rng, 0.35),
                    y=sample.y + _noise(rng, 0.35),
                    label="target",
                    target_id=0,
                )
            )
    return ScenarioSpec(
        name="latency_stress",
        description="High event-rate window to stress Libellula latency and FIFO handling.",
        events=events_target,
        truth_map=truth,
        assumption_notes=[
            "Cycles 120-180 emit 4x events to mimic high-rate segments.",
            "Latency measured against the first event in each micro-burst.",
        ],
        metadata={"peak_events_per_cycle": 4},
    )


def enumerate_scenarios() -> List[ScenarioSpec]:
    return [
        scenario_linear_motion(),
        scenario_abrupt_acceleration(),
        scenario_distractor_crossing(),
        scenario_partial_occlusion(),
        scenario_noise_bursts(),
        scenario_latency_stress(),
    ]


__all__ = [
    "ScenarioEvent",
    "TruthSample",
    "ScenarioSpec",
    "enumerate_scenarios",
]

