"""Shot boundary detection: TransNetV2 (streaming windows) or PySceneDetect, boundary typing,
frame-accurate snapping of hard cuts."""
from __future__ import annotations

from pathlib import Path
from typing import Iterator

import cv2
import numpy as np

from .log import log


def iter_frames(path: Path, start: int = 0, stop: int | None = None) -> Iterator[tuple[int, np.ndarray]]:
    """Stream BGR frames [start, stop) from a video file without holding more than one in memory."""
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        raise RuntimeError(f"cannot open {path}")
    if start:
        cap.set(cv2.CAP_PROP_POS_FRAMES, start)
    idx = start
    try:
        while stop is None or idx < stop:
            ok, frame = cap.read()
            if not ok:
                break
            yield idx, frame
            idx += 1
    finally:
        cap.release()


def read_frames_range(path: Path, start: int, stop: int) -> list[np.ndarray]:
    return [f for _, f in iter_frames(path, max(0, start), stop)]


# ---------------------------------------------------------------------------
# TransNetV2
# ---------------------------------------------------------------------------

_TRANSNET = None


def load_transnet(device: str = "cpu"):
    global _TRANSNET
    if _TRANSNET is None:
        from transnetv2_pytorch import TransNetV2  # weights ship inside the wheel
        model = TransNetV2(device=device)
        model.eval()
        _TRANSNET = model
    return _TRANSNET


def detect_transnet(proxy: Path, threshold: float = 0.5, device: str = "cpu") -> tuple[np.ndarray, np.ndarray, int]:
    """Streaming TransNetV2.  Returns (single_frame_pred, many_hot_pred, n_frames) with one value per frame.

    Replicates the reference windowing (100-frame windows, 50-frame step, 25-frame padding
    at both ends) while holding at most ~150 tiny 48x27 frames in memory.
    """
    import torch
    model = load_transnet(device)
    win, step, pad = 100, 50, 25
    buf: list[np.ndarray] = []
    single: list[np.ndarray] = []
    many: list[np.ndarray] = []
    n = 0
    last = None

    def flush():
        while len(buf) >= win:
            batch = torch.from_numpy(np.stack(buf[:win])[np.newaxis]).to(model.device)
            with torch.no_grad():
                s, m = model.predict_raw(batch)
            single.append(s[0, pad:pad + step, 0].cpu().numpy())
            many.append(m[0, pad:pad + step, 0].cpu().numpy())
            del buf[:step]

    for _, frame in iter_frames(proxy):
        small = cv2.cvtColor(cv2.resize(frame, (48, 27), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2RGB)
        if n == 0:
            buf.extend([small] * pad)
        buf.append(small)
        last = small
        n += 1
        if len(buf) >= win + step:
            flush()
    if n == 0:
        return np.zeros(0), np.zeros(0), 0
    tail = pad + step - (n % step if n % step else step)
    buf.extend([last] * tail)
    flush()
    sp = np.concatenate(single)[:n]
    mp = np.concatenate(many)[:n]
    return sp, mp, n


def transitions_from_predictions(single: np.ndarray, many: np.ndarray, threshold: float) -> list[tuple[int, int]]:
    """Group predicted transition frames into spans [first, last] (inclusive, frame indices)."""
    flags = (single > threshold)
    spans = []
    i, n = 0, len(flags)
    while i < n:
        if flags[i]:
            j = i
            while j + 1 < n and (flags[j + 1] or many[j + 1] > threshold):
                j += 1
            # widen with the many-hot prediction to capture gradual transitions
            a = i
            while a - 1 >= 0 and many[a - 1] > threshold:
                a -= 1
            spans.append((a, j))
            i = j + 1
        else:
            i += 1
    # merge overlapping / adjacent spans
    merged: list[tuple[int, int]] = []
    for a, b in spans:
        if merged and a <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    return merged


# ---------------------------------------------------------------------------
# PySceneDetect fallback
# ---------------------------------------------------------------------------

def detect_pyscenedetect(proxy: Path, threshold: float = 27.0, min_scene_len: int = 2) -> list[tuple[int, int]]:
    """Return transition spans [(f, f)] from ContentDetector + ThresholdDetector (fades)."""
    from scenedetect import open_video, SceneManager, ContentDetector, ThresholdDetector
    video = open_video(str(proxy))
    sm = SceneManager()
    sm.add_detector(ContentDetector(threshold=threshold, min_scene_len=min_scene_len))
    sm.add_detector(ThresholdDetector(threshold=12, min_scene_len=min_scene_len, fade_bias=0.0))
    sm.detect_scenes(video, show_progress=False)
    cuts = sorted({c.get_frames() for c in sm.get_cut_list()})
    merged: list[tuple[int, int]] = []
    for c in cuts:
        if merged and c - merged[-1][1] <= 3:
            merged[-1] = (merged[-1][0], c)
        else:
            merged.append((c, c))
    return merged


# ---------------------------------------------------------------------------
# Boundary typing and snapping
# ---------------------------------------------------------------------------

def _luma_series(frames: list[np.ndarray]) -> np.ndarray:
    return np.array([cv2.cvtColor(cv2.resize(f, (64, 36), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2GRAY).mean()
                     for f in frames], dtype=np.float32)


def _hist_diffs(frames: list[np.ndarray]) -> np.ndarray:
    hs = []
    for f in frames:
        small = cv2.resize(f, (64, 36), interpolation=cv2.INTER_AREA)
        hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
        h = cv2.calcHist([hsv], [0, 1, 2], None, [8, 4, 4], [0, 180, 0, 256, 0, 256]).flatten()
        hs.append(h / (h.sum() + 1e-9))
    hs = np.array(hs)
    return np.abs(np.diff(hs, axis=0)).sum(axis=1) if len(hs) > 1 else np.zeros(0)


def type_and_snap(proxy: Path, spans: list[tuple[int, int]], n_frames: int) -> list[tuple[int, str]]:
    """For each transition span, return (boundary_frame, type).

    boundary_frame is the first frame of the new shot.  Hard cuts are snapped to the
    largest inter-frame difference within +/-3 frames of the predicted position so the
    in/out points are frame-accurate.  Types: cut | dissolve | fade.
    """
    out: list[tuple[int, str]] = []
    for a, b in spans:
        lo, hi = max(0, a - 4), min(n_frames, b + 5)
        frames = read_frames_range(proxy, lo, hi)
        if len(frames) < 2:
            out.append((min(max(b, 1), n_frames - 1), "cut"))
            continue
        luma = _luma_series(frames)
        diffs = _hist_diffs(frames)              # diffs[k] = |frame lo+k+1 - frame lo+k|
        span_len = b - a + 1
        near_black = (luma < 16).any()
        near_white = (luma > 240).any()
        if span_len >= 3 and (near_black or near_white):
            ttype = "fade"
        elif span_len >= 3:
            ttype = "dissolve"
        elif near_black and span_len >= 1 and (luma.min() < 10) and (luma.max() > 60):
            ttype = "fade"
        else:
            ttype = "cut"
        if ttype == "cut":
            k = int(np.argmax(diffs))
            # if one difference dominates, it is the cut; otherwise it is a short gradual
            if diffs.sum() > 0 and diffs[k] / diffs.sum() < 0.45 and span_len >= 2:
                ttype = "dissolve"
                boundary = (a + b + 1) // 2
            else:
                boundary = lo + k + 1
        else:
            boundary = (a + b + 1) // 2
            if ttype == "fade":
                # put the boundary at the darkest (or brightest) frame
                k = int(np.argmin(luma)) if near_black else int(np.argmax(luma))
                boundary = lo + k
        boundary = int(min(max(boundary, 1), n_frames - 1))
        out.append((boundary, ttype))
    # de-duplicate boundaries that collapsed onto the same frame
    dedup: list[tuple[int, str]] = []
    for bf, t in sorted(out):
        if dedup and bf - dedup[-1][0] < 2:
            continue
        dedup.append((bf, t))
    return dedup


def boundaries_to_shots(boundaries: list[tuple[int, str]], n_frames: int, min_frames: int = 2) -> list[tuple[int, int, str, str]]:
    """Return contiguous shots [(start, end_exclusive, in_type, out_type)] covering [0, n_frames)."""
    bs = [(0, "start")] + [(f, t) for f, t in boundaries if 0 < f < n_frames] + [(n_frames, "end")]
    shots = []
    carry = None            # a too-short opening fragment is merged forward into the next shot
    for (s, tin), (e, tout) in zip(bs[:-1], bs[1:]):
        if carry is not None:
            s, tin = carry
            carry = None
        if e - s < min_frames:
            if shots:
                ps, pe, pin, _ = shots[-1]
                shots[-1] = (ps, e, pin, tout)
            else:
                carry = (s, tin)
        else:
            shots.append((s, e, tin, tout))
    if carry is not None:
        shots.append((carry[0], n_frames, carry[1], "end"))
    return shots


def detect(proxy: Path, detector: str, n_frames_hint: int | None, transnet_threshold: float,
           psd_threshold: float, min_frames: int, device: str = "cpu") -> tuple[list[tuple[int, int, str, str]], str, int]:
    """Run the configured detector; return (shots, detector_name, n_frames)."""
    name = detector
    spans: list[tuple[int, int]] = []
    n = 0
    if detector in ("auto", "transnetv2"):
        try:
            single, many, n = detect_transnet(proxy, transnet_threshold, device)
            spans = transitions_from_predictions(single, many, transnet_threshold)
            name = "transnetv2"
        except Exception as e:  # ImportError or runtime failure -> fallback
            if detector == "transnetv2":
                raise
            log.warning("TransNetV2 unavailable (%s); falling back to PySceneDetect", e)
            name = "pyscenedetect"
    if name in ("pyscenedetect", "auto") or not n:
        spans = detect_pyscenedetect(proxy, psd_threshold, min_frames)
        name = "pyscenedetect"
    if not n:
        n = sum(1 for _ in iter_frames(proxy))
    boundaries = type_and_snap(proxy, spans, n)
    return boundaries_to_shots(boundaries, n, min_frames), name, n
