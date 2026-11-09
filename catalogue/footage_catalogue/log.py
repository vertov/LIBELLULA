"""Logging and per-file timing / ETA."""
from __future__ import annotations

import csv
import logging
import time
from datetime import datetime
from pathlib import Path

log = logging.getLogger("fcat")


def setup_logging(logs_dir: Path, verbose: bool = False) -> Path:
    logs_dir.mkdir(parents=True, exist_ok=True)
    path = logs_dir / f"run_{datetime.now():%Y%m%d_%H%M%S}.log"
    log.setLevel(logging.DEBUG)
    log.handlers.clear()
    fh = logging.FileHandler(path, encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    ch = logging.StreamHandler()
    ch.setLevel(logging.DEBUG if verbose else logging.INFO)
    ch.setFormatter(logging.Formatter("%(asctime)s %(message)s", "%H:%M:%S"))
    log.addHandler(fh)
    log.addHandler(ch)
    # quieten noisy libraries
    for name in ("faster_whisper", "transformers", "torch", "PIL", "urllib3", "httpx"):
        logging.getLogger(name).setLevel(logging.WARNING)
    return path


class Timer:
    def __init__(self):
        self.t0 = time.perf_counter()
        self.marks: dict[str, float] = {}

    def lap(self, name: str) -> float:
        t = time.perf_counter()
        self.marks[name] = t - self.t0
        self.t0 = t
        return self.marks[name]


class Eta:
    """Tracks processing speed (seconds of work per second of footage) and estimates the remainder."""

    def __init__(self, total_footage_sec: float, timings_csv: Path):
        self.total = total_footage_sec
        self.done_footage = 0.0
        self.done_work = 0.0
        self.n = 0
        self.csv = timings_csv
        new = not timings_csv.exists()
        self._fh = open(timings_csv, "a", newline="", encoding="utf-8")
        self._w = csv.writer(self._fh)
        if new:
            self._w.writerow(["timestamp", "file", "footage_sec", "proxy_s", "l1_s", "l2_s", "l3_s", "l4_s", "total_s", "realtime_factor"])

    def record(self, name: str, footage_sec: float, marks: dict[str, float]) -> None:
        total = sum(marks.values())
        self.done_footage += footage_sec
        self.done_work += total
        self.n += 1
        rtf = total / footage_sec if footage_sec else 0.0
        self._w.writerow([datetime.now().isoformat(timespec="seconds"), name, f"{footage_sec:.2f}",
                          *(f"{marks.get(k, 0.0):.1f}" for k in ("proxy", "l1", "l2", "l3", "l4")),
                          f"{total:.1f}", f"{rtf:.3f}"])
        self._fh.flush()

    def estimate(self) -> tuple[float, float]:
        """Return (speed_factor, remaining_seconds)."""
        if self.done_footage <= 0:
            return 0.0, 0.0
        factor = self.done_work / self.done_footage
        remaining = max(0.0, self.total - self.done_footage) * factor
        return factor, remaining

    def close(self):
        self._fh.close()


def fmt_dur(sec: float) -> str:
    sec = int(round(sec))
    h, r = divmod(sec, 3600)
    m, s = divmod(r, 60)
    return f"{h:d}:{m:02d}:{s:02d}" if h else f"{m:d}:{s:02d}"
