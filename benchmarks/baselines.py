"""Software baseline trackers used for comparison."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Sequence, Tuple
import math

from .scenarios import ScenarioEvent


@dataclass
class TrackerPrediction:
    horizon: int
    x: float
    y: float
    locked: bool


@dataclass
class TrackerSample:
    cycle: int
    predictions: List[TrackerPrediction]
    latency_cycles: int
    compute_cost: float
    locked: bool


class TrackerBase:
    """Common interface for tracker baselines."""

    name: str = "tracker"
    cost_per_event: float = 1.0

    def __init__(self, dt_cycles: float = 1.0):
        self.dt = dt_cycles
        self.samples: List[TrackerSample] = []
        self.last_cycle = 0
        self.latency_cycles = 2  # best-effort modeling
        self.locked_flag = False
        self._pending_cost = 0.0

    def reset(self):
        self.samples.clear()
        self.last_cycle = 0
        self.locked_flag = False
        self._pending_cost = 0.0

    def handle(self, cycle: int, events: Sequence[ScenarioEvent]) -> None:
        """Update tracker state with events observed at this cycle."""
        raise NotImplementedError

    def predict(self, cycle: int, horizons: Sequence[int]) -> List[TrackerPrediction]:
        raise NotImplementedError

    def step(self, cycle: int, events: Sequence[ScenarioEvent], horizons: Sequence[int]) -> TrackerSample:
        self.handle(cycle, events)
        preds = self.predict(cycle, horizons)
        sample = TrackerSample(
            cycle=cycle,
            predictions=preds,
            latency_cycles=self.latency_cycles,
            compute_cost=self._pending_cost,
            locked=self.locked_flag,
        )
        self._pending_cost = 0.0
        self.samples.append(sample)
        self.last_cycle = cycle
        return sample

    def _account_cost(self, events_processed: int, weight: float = 1.0) -> None:
        self._pending_cost += self.cost_per_event * events_processed * weight


class ConstantVelocityNNTracker(TrackerBase):
    name = "constant_velocity_nn"
    cost_per_event = 1.0

    def __init__(self, dt_cycles: float = 1.0, gating_radius: float = 6.0):
        super().__init__(dt_cycles)
        self.gating_radius = gating_radius
        self.state_x: float | None = None
        self.state_y: float | None = None
        self.vx = 0.0
        self.vy = 0.0
        self.last_obs_cycle = 0
        self.latency_cycles = 3

    def reset(self):
        super().reset()
        self.state_x = None
        self.state_y = None
        self.vx = 0.0
        self.vy = 0.0
        self.last_obs_cycle = 0

    def _predict_state(self, cycle: int) -> Tuple[float, float]:
        if self.state_x is None or self.state_y is None:
            return 0.0, 0.0
        dt = cycle - self.last_obs_cycle
        return self.state_x + self.vx * dt, self.state_y + self.vy * dt

    def handle(self, cycle: int, events: Sequence[ScenarioEvent]) -> None:
        self._account_cost(len(events))
        if not events:
            age = cycle - self.last_obs_cycle
            # velocity decay when no observations
            if age > 0:
                self.vx *= 0.98
                self.vy *= 0.98
            self.locked_flag = self.state_x is not None
            return

        if self.state_x is None or self.state_y is None:
            best_event = events[0]
        else:
            pred_x, pred_y = self._predict_state(cycle)
            best_event = min(events, key=lambda e: (e.x - pred_x) ** 2 + (e.y - pred_y) ** 2)
            dist = math.hypot(best_event.x - pred_x, best_event.y - pred_y)
            if dist > self.gating_radius:
                # treat as loss of lock until measurement is close again
                self.locked_flag = False
                return

        dt = max(1, cycle - self.last_obs_cycle)
        if self.state_x is not None and self.state_y is not None:
            self.vx = (best_event.x - self.state_x) / dt
            self.vy = (best_event.y - self.state_y) / dt
        self.state_x = best_event.x
        self.state_y = best_event.y
        self.last_obs_cycle = cycle
        self.locked_flag = True

    def predict(self, cycle: int, horizons: Sequence[int]) -> List[TrackerPrediction]:
        preds: List[TrackerPrediction] = []
        if self.state_x is None or self.state_y is None:
            return preds
        pos_x, pos_y = self._predict_state(cycle)
        for horizon in horizons:
            preds.append(
                TrackerPrediction(
                    horizon=horizon,
                    x=pos_x + self.vx * horizon,
                    y=pos_y + self.vy * horizon,
                    locked=self.locked_flag,
                )
            )
        return preds


class KalmanTracker(TrackerBase):
    name = "kalman_tracking"
    cost_per_event = 3.0  # extra matrix math

    def __init__(self, dt_cycles: float = 1.0, meas_var: float = 0.6, process_var: float = 0.2):
        super().__init__(dt_cycles)
        self.meas_var = meas_var
        self.process_var = process_var
        self.state = [0.0, 0.0, 0.0, 0.0]  # x, vx, y, vy
        self.P = [
            [10.0, 0.0, 0.0, 0.0],
            [0.0, 10.0, 0.0, 0.0],
            [0.0, 0.0, 10.0, 0.0],
            [0.0, 0.0, 0.0, 10.0],
        ]
        self.F = [
            [1.0, self.dt, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, self.dt],
            [0.0, 0.0, 0.0, 1.0],
        ]
        self.H = [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
        ]
        q = self.process_var
        self.Q = [
            [q, 0.0, 0.0, 0.0],
            [0.0, q, 0.0, 0.0],
            [0.0, 0.0, q, 0.0],
            [0.0, 0.0, 0.0, q],
        ]
        r = self.meas_var
        self.R = [
            [r, 0.0],
            [0.0, r],
        ]
        self.locked_flag = False
        self.latency_cycles = 5

    def reset(self):
        super().reset()
        self.state = [0.0, 0.0, 0.0, 0.0]
        for i in range(4):
            for j in range(4):
                self.P[i][j] = 0.0
        for i in range(4):
            self.P[i][i] = 10.0
        self.locked_flag = False

    def _matmul(self, A: List[List[float]], B: List[List[float]]) -> List[List[float]]:
        rows = len(A)
        cols = len(B[0])
        mid = len(B)
        result = [[0.0 for _ in range(cols)] for __ in range(rows)]
        for i in range(rows):
            for k in range(mid):
                aik = A[i][k]
                if aik == 0.0:
                    continue
                for j in range(cols):
                    result[i][j] += aik * B[k][j]
        return result

    def _mat_add(self, A: List[List[float]], B: List[List[float]]) -> List[List[float]]:
        rows = len(A)
        cols = len(A[0])
        return [[A[i][j] + B[i][j] for j in range(cols)] for i in range(rows)]

    def _mat_sub(self, A: List[List[float]], B: List[List[float]]) -> List[List[float]]:
        rows = len(A)
        cols = len(A[0])
        return [[A[i][j] - B[i][j] for j in range(cols)] for i in range(rows)]

    def _transpose(self, A: List[List[float]]) -> List[List[float]]:
        return [list(row) for row in zip(*A)]

    def _inv2(self, A: List[List[float]]) -> List[List[float]]:
        det = A[0][0] * A[1][1] - A[0][1] * A[1][0]
        if abs(det) < 1e-9:
            det = 1e-9
        inv_det = 1.0 / det
        return [
            [A[1][1] * inv_det, -A[0][1] * inv_det],
            [-A[1][0] * inv_det, A[0][0] * inv_det],
        ]

    def _predict_process(self):
        # x_k = F x_{k-1}
        s = self.state
        F = self.F
        x = [
            F[0][0] * s[0] + F[0][1] * s[1],
            F[1][0] * s[0] + F[1][1] * s[1],
            F[2][2] * s[2] + F[2][3] * s[3],
            F[3][2] * s[2] + F[3][3] * s[3],
        ]
        self.state = x
        Ft = self._transpose(self.F)
        self.P = self._mat_add(self._matmul(self._matmul(self.F, self.P), Ft), self.Q)

    def handle(self, cycle: int, events: Sequence[ScenarioEvent]) -> None:
        self._account_cost(len(events), weight=1.5)  # Kalman needs more math per event
        self._predict_process()
        if not events:
            self.locked_flag = False
            return
        # use centroid of events at this cycle as measurement
        mx = sum(e.x for e in events) / len(events)
        my = sum(e.y for e in events) / len(events)
        z = [[mx], [my]]

        H = self.H
        PHT = self._matmul(self.P, self._transpose(H))
        HPHT = self._matmul(H, PHT)
        S = self._mat_add(HPHT, self.R)
        S_inv = self._inv2(S)
        K = self._matmul(PHT, S_inv)

        hx = [
            H[0][0] * self.state[0] + H[0][1] * self.state[1] + H[0][2] * self.state[2] + H[0][3] * self.state[3],
            H[1][0] * self.state[0] + H[1][1] * self.state[1] + H[1][2] * self.state[2] + H[1][3] * self.state[3],
        ]
        y_res = [[z[0][0] - hx[0]], [z[1][0] - hx[1]]]
        state_updates = self._matmul(K, y_res)
        for i in range(4):
            self.state[i] += state_updates[i][0]

        I = [[1.0 if i == j else 0.0 for j in range(4)] for i in range(4)]
        KH = self._matmul(K, H)
        self.P = self._matmul(self._mat_sub(I, KH), self.P)
        self.locked_flag = True

    def predict(self, cycle: int, horizons: Sequence[int]) -> List[TrackerPrediction]:
        preds: List[TrackerPrediction] = []
        if not self.locked_flag:
            return preds
        x, vx, y, vy = self.state
        for horizon in horizons:
            preds.append(
                TrackerPrediction(
                    horizon=horizon,
                    x=x + vx * horizon,
                    y=y + vy * horizon,
                    locked=True,
                )
            )
        return preds


class EventMotionBaseline(TrackerBase):
    """Extrapolates using local event motion vectors."""

    name = "event_motion"
    cost_per_event = 0.7

    def __init__(self, dt_cycles: float = 1.0, window: int = 6):
        super().__init__(dt_cycles)
        self.window = window
        self.history: List[Tuple[int, float, float]] = []
        self.position = (0.0, 0.0)
        self.velocity = (0.0, 0.0)
        self.locked_flag = False
        self.latency_cycles = 2

    def reset(self):
        super().reset()
        self.history.clear()
        self.position = (0.0, 0.0)
        self.velocity = (0.0, 0.0)

    def handle(self, cycle: int, events: Sequence[ScenarioEvent]) -> None:
        self._account_cost(len(events), weight=0.6)
        if events:
            centroid_x = sum(e.x for e in events) / len(events)
            centroid_y = sum(e.y for e in events) / len(events)
            self.history.append((cycle, centroid_x, centroid_y))
            if len(self.history) > self.window:
                self.history.pop(0)
            if len(self.history) >= 2:
                first = self.history[0]
                last = self.history[-1]
                dt = max(1, last[0] - first[0])
                self.velocity = ((last[1] - first[1]) / dt, (last[2] - first[2]) / dt)
                self.position = (last[1], last[2])
                self.locked_flag = True
        else:
            # drift in absence of data
            self.velocity = (self.velocity[0] * 0.95, self.velocity[1] * 0.95)
            self.locked_flag = False

    def predict(self, cycle: int, horizons: Sequence[int]) -> List[TrackerPrediction]:
        preds: List[TrackerPrediction] = []
        px, py = self.position
        vx, vy = self.velocity
        if not self.history:
            return preds
        for horizon in horizons:
            preds.append(
                TrackerPrediction(
                    horizon=horizon,
                    x=px + vx * horizon,
                    y=py + vy * horizon,
                    locked=self.locked_flag,
                )
            )
        return preds


class TinyLearnedPredictor(TrackerBase):
    """Online linear regressor trained on-the-fly."""

    name = "tiny_learned"
    cost_per_event = 1.5

    def __init__(self, dt_cycles: float = 1.0, learning_rate: float = 0.05):
        super().__init__(dt_cycles)
        self.lr = learning_rate
        # Feature vector: [1, x, y, vx, vy]
        self.weights_x = [0.0, 1.0, 0.0, 0.1, 0.0]
        self.weights_y = [0.0, 0.0, 1.0, 0.0, 0.1]
        self.last_position = (0.0, 0.0)
        self.velocity = (0.0, 0.0)
        self.latency_cycles = 6

    def reset(self):
        super().reset()
        self.weights_x = [0.0, 1.0, 0.0, 0.1, 0.0]
        self.weights_y = [0.0, 0.0, 1.0, 0.0, 0.1]

    def _features(self) -> List[float]:
        return [1.0, self.last_position[0], self.last_position[1], self.velocity[0], self.velocity[1]]

    def _predict_delta(self, weights: List[float]) -> float:
        feats = self._features()
        return sum(w * f for w, f in zip(weights, feats))

    def handle(self, cycle: int, events: Sequence[ScenarioEvent]) -> None:
        self._account_cost(len(events), weight=1.2)
        if events:
            centroid_x = sum(e.x for e in events) / len(events)
            centroid_y = sum(e.y for e in events) / len(events)
            meas_vx = centroid_x - self.last_position[0]
            meas_vy = centroid_y - self.last_position[1]
            target_dx = centroid_x - self.last_position[0]
            target_dy = centroid_y - self.last_position[1]
            feats = self._features()
            pred_dx = sum(w * f for w, f in zip(self.weights_x, feats))
            pred_dy = sum(w * f for w, f in zip(self.weights_y, feats))
            err_x = target_dx - pred_dx
            err_y = target_dy - pred_dy
            for i in range(len(self.weights_x)):
                self.weights_x[i] += self.lr * err_x * feats[i]
                self.weights_y[i] += self.lr * err_y * feats[i]
            self.velocity = (0.5 * self.velocity[0] + 0.5 * meas_vx, 0.5 * self.velocity[1] + 0.5 * meas_vy)
            self.last_position = (centroid_x, centroid_y)
            self.locked_flag = True
        else:
            self.velocity = (self.velocity[0] * 0.9, self.velocity[1] * 0.9)
            self.locked_flag = False

    def predict(self, cycle: int, horizons: Sequence[int]) -> List[TrackerPrediction]:
        preds: List[TrackerPrediction] = []
        feats = self._features()
        base_x = self.last_position[0]
        base_y = self.last_position[1]
        pred_dx = sum(w * f for w, f in zip(self.weights_x, feats))
        pred_dy = sum(w * f for w, f in zip(self.weights_y, feats))
        for horizon in horizons:
            preds.append(
                TrackerPrediction(
                    horizon=horizon,
                    x=base_x + pred_dx * horizon,
                    y=base_y + pred_dy * horizon,
                    locked=self.locked_flag,
                )
            )
        return preds


def build_baselines(dt_cycles: float = 1.0) -> Dict[str, TrackerBase]:
    """Factory returning all baseline tracker instances."""
    baselines: Dict[str, TrackerBase] = {
        "constant_velocity_nn": ConstantVelocityNNTracker(dt_cycles),
        "kalman": KalmanTracker(dt_cycles),
        "event_motion": EventMotionBaseline(dt_cycles),
        "tiny_learned": TinyLearnedPredictor(dt_cycles),
    }
    return baselines


__all__ = [
    "TrackerBase",
    "TrackerSample",
    "TrackerPrediction",
    "ConstantVelocityNNTracker",
    "KalmanTracker",
    "EventMotionBaseline",
    "TinyLearnedPredictor",
    "build_baselines",
]

