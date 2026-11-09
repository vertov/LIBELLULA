"""Layer 1: per-shot visual features from a single streaming pass over the proxy.

Colour, brightness, contrast, dominant colours, optical flow split into camera
and in-frame motion, complexity, perceptual hash, key frame + filmstrip JPEGs,
and 1 Hz trajectories for Layer 4.
"""
from __future__ import annotations

import math
from pathlib import Path

import cv2
import imagehash
import numpy as np
from PIL import Image

from .config import Config
from .log import log
from .shots import iter_frames

HUE_NAMES = [(15, "red"), (45, "orange"), (70, "yellow"), (165, "green"), (200, "cyan"),
             (260, "blue"), (300, "purple"), (345, "magenta"), (361, "red")]


def hue_name(deg: float | None, sat: float) -> str:
    if deg is None or sat < 0.12:
        return "neutral"
    for lim, name in HUE_NAMES:
        if deg < lim:
            return name
    return "red"


def _hex(bgr) -> str:
    b, g, r = (int(round(x)) for x in bgr)
    return f"#{r:02x}{g:02x}{b:02x}"


def dominant_colors(pixels: np.ndarray, k: int = 5) -> list[dict]:
    """k-means over a BGR pixel sample -> [{"hex", "frac", "h", "s", "v"}] sorted by frac."""
    if len(pixels) == 0:
        return []
    k = int(min(k, max(1, len(np.unique(pixels, axis=0)))))
    data = pixels.astype(np.float32)
    crit = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 20, 1.0)
    _, labels, centers = cv2.kmeans(data, k, None, crit, 2, cv2.KMEANS_PP_CENTERS)
    counts = np.bincount(labels.flatten(), minlength=k).astype(np.float64)
    order = np.argsort(-counts)
    out = []
    for i in order:
        c = np.clip(centers[i], 0, 255)
        hsv = cv2.cvtColor(np.uint8([[c]]), cv2.COLOR_BGR2HSV)[0, 0]
        out.append({"hex": _hex(c), "frac": round(float(counts[i] / counts.sum()), 4),
                    "h": int(hsv[0]) * 2, "s": round(int(hsv[1]) / 255, 3), "v": round(int(hsv[2]) / 255, 3)})
    return out


def _strip_positions(n_frames: int, fps: float, cfg: Config) -> list[float]:
    dur = n_frames / fps
    k = cfg.strip_frames if (dur >= cfg.vision_min_shot_sec and n_frames >= 8) else 2
    k = max(2, min(k, n_frames))
    if k == 2:
        return [0.2, 0.8]
    return [(i + 0.5) / k for i in range(k)]


class _ShotAcc:
    """Accumulates per-shot statistics while frames stream by."""

    def __init__(self, idx: int, start: int, end: int, fps: float, cfg: Config, w: int, h: int):
        self.idx, self.start, self.end, self.fps = idx, start, end, fps
        n = end - start
        self.key_frame = start + n // 2
        self.strip_frames = sorted({start + min(n - 1, int(p * n)) for p in _strip_positions(n, fps, cfg)})
        self.bright: list[float] = []
        self.contrast: list[float] = []
        self.sat: list[float] = []
        self.edges: list[float] = []
        self.pix: list[np.ndarray] = []
        self.cam: list[float] = []
        self.inframe: list[float] = []
        self.total: list[float] = []
        self.dx: list[float] = []
        self.dy: list[float] = []
        self.zoom: list[float] = []
        self.center_ratio: list[float] = []
        self.prev_gray: np.ndarray | None = None
        self.saved: dict[int, str] = {}
        self.key_path: str | None = None
        self.phash: str | None = None
        self.jpeg_complexity: float | None = None
        self.hue_sin = 0.0
        self.hue_cos = 0.0
        self.hue_w = 0.0
        self.n_sampled = 0
        self.max_pix_frames = 40
        self.frame_w = w
        self.frame_h = h


def _global_motion(flow: np.ndarray, gray: np.ndarray) -> tuple[float, float, float, float, float, float]:
    """Fit a similarity transform to the flow field on textured pixels only.

    Flat regions carry no measurable flow and would otherwise vote for "no motion"; the fit and
    all magnitudes are therefore restricted to pixels with image gradient.  Returns
    (dx, dy, scale, cam_mag, inframe_mag, center_ratio); magnitudes in pixels per analysed step.
    """
    h, w = flow.shape[:2]
    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    grad = cv2.magnitude(gx, gy)
    thr = max(20.0, float(np.percentile(grad, 60)))
    mask = cv2.dilate((grad > thr).astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool)
    if mask.sum() < 200:
        mask = np.ones((h, w), dtype=bool)
    ys, xs = np.nonzero(mask[::4, ::4])
    ys, xs = ys * 4, xs * 4
    if len(xs) > 3000:
        sel = np.random.choice(len(xs), 3000, replace=False)
        ys, xs = ys[sel], xs[sel]
    pts = np.stack([xs, ys], axis=1).astype(np.float32)
    dst = pts + flow[ys, xs]
    M = None
    if len(pts) >= 12:
        M, _ = cv2.estimateAffinePartial2D(pts, dst, method=cv2.RANSAC, ransacReprojThreshold=1.0, maxIters=300)
    if M is None:
        g = np.zeros_like(flow)
        dx = dy = 0.0
        scale = 1.0
    else:
        scale = float(math.hypot(M[0, 0], M[0, 1]))
        mx, my = np.meshgrid(np.arange(w, dtype=np.float32), np.arange(h, dtype=np.float32))
        g = np.dstack([M[0, 0] * mx + M[0, 1] * my + M[0, 2] - mx, M[1, 0] * mx + M[1, 1] * my + M[1, 2] - my])
        # translation reported at the frame centre (zoom/rotation add no net shift there)
        cx, cy = w / 2.0, h / 2.0
        dx = float(M[0, 0] * cx + M[0, 1] * cy + M[0, 2] - cx)
        dy = float(M[1, 0] * cx + M[1, 1] * cy + M[1, 2] - cy)
    gm = np.linalg.norm(g, axis=2)
    cam_mag = float(gm[mask].mean())
    rmag = np.linalg.norm(flow - g, axis=2)
    inframe = float(rmag[mask].mean())
    fm = np.linalg.norm(flow, axis=2)
    cy0, cy1, cx0, cx1 = h // 3, 2 * h // 3, w // 3, 2 * w // 3
    cmask = np.zeros_like(mask); cmask[cy0:cy1, cx0:cx1] = True
    center = fm[mask & cmask].mean() if (mask & cmask).any() else 0.0
    periph = fm[mask & ~cmask].mean() if (mask & ~cmask).any() else 0.0
    ratio = float(center / (periph + 1e-6))
    return dx, dy, scale, cam_mag, inframe, ratio


def classify_camera_motion(cam: float, inframe: float, dx: float, dy: float, zoom: float, jitter: float,
                           center_ratio: float, zoom_coh: float = 1.0) -> str:
    """Heuristic camera-motion class from normalised flow statistics.

    cam / inframe / dx / dy are fractions of frame width per source frame; zoom is the per-frame
    scale change; jitter is 1 - directional coherence of the per-step camera vectors (0 = perfectly
    steady, 1 = random); center_ratio compares flow magnitude in the central third to the periphery.
    """
    speed = math.hypot(dx, dy)
    if abs(zoom) > 0.002 and zoom_coh > 0.7 and abs(zoom) * 2.0 > speed:
        return "zoom"
    if cam < 0.0008:
        return "static"
    if jitter > 0.55:
        return "handheld"
    if center_ratio < 0.3 and inframe > 0.35 * cam:
        return "tracking"            # subject held in frame while the background streams past
    if abs(dx) > 2.0 * abs(dy):
        return "pan"
    if abs(dy) > 2.0 * abs(dx):
        return "tilt"
    return "tracking"                # steady diagonal / combined move


def analyze(proxy: Path, shots: list[tuple[int, int, str, str]], fps: float, cfg: Config,
            thumb_dir: Path) -> tuple[list[dict], dict]:
    """Single streaming pass.  Returns (per-shot dicts with Layer 1 fields, trajectories)."""
    thumb_dir.mkdir(parents=True, exist_ok=True)
    stride = max(1, cfg.analysis_stride)
    accs = []
    cap = cv2.VideoCapture(str(proxy))
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)) or 854
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)) or 480
    cap.release()
    for i, (s, e, tin, tout) in enumerate(shots):
        accs.append(_ShotAcc(i, s, e, fps, cfg, w, h))
    fw = cfg.flow_width
    fh = max(2, int(round(h * fw / w / 2)) * 2)
    starts = np.array([s for s, _, _, _ in shots])
    traj_bright: dict[int, list[float]] = {}
    traj_motion: dict[int, list[float]] = {}
    traj_sat: dict[int, list[float]] = {}
    tw = cfg.thumb_width
    th = max(2, int(round(h * tw / w)))

    cur = 0
    for idx, frame in iter_frames(proxy):
        while cur + 1 < len(accs) and idx >= accs[cur + 1].start:
            cur += 1
        acc = accs[cur]
        # --- frame saves (key frame / filmstrip), any frame -------------------
        if idx == acc.key_frame or idx in acc.strip_frames:
            thumb = cv2.resize(frame, (tw, th), interpolation=cv2.INTER_AREA)
            if idx in acc.strip_frames:
                k = acc.strip_frames.index(idx)
                p = thumb_dir / f"shot_{acc.idx:04d}_f{k}.jpg"
                cv2.imwrite(str(p), thumb, [cv2.IMWRITE_JPEG_QUALITY, 85])
                acc.saved[k] = p.name
            if idx == acc.key_frame:
                p = thumb_dir / f"shot_{acc.idx:04d}_key.jpg"
                cv2.imwrite(str(p), thumb, [cv2.IMWRITE_JPEG_QUALITY, 88])
                acc.key_path = p.name
                ok, enc = cv2.imencode(".jpg", thumb, [cv2.IMWRITE_JPEG_QUALITY, 75])
                acc.jpeg_complexity = float(len(enc)) / (tw * th) if ok else None
                acc.phash = str(imagehash.phash(Image.fromarray(cv2.cvtColor(thumb, cv2.COLOR_BGR2RGB))))
        if (idx - acc.start) % stride:
            continue
        # --- sampled analysis ----------------------------------------------------
        small = cv2.resize(frame, (fw, fh), interpolation=cv2.INTER_AREA)
        gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
        hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
        bright = float(gray.mean()) / 255.0
        contrast = float(gray.std()) / 255.0
        sat = float(hsv[..., 1].mean()) / 255.0
        acc.bright.append(bright)
        acc.contrast.append(contrast)
        acc.sat.append(sat)
        # weighted circular hue mean (weights: saturation * value)
        hh = hsv[..., 0].astype(np.float32) * (2 * np.pi / 180.0)
        wgt = (hsv[..., 1].astype(np.float32) / 255.0) * (hsv[..., 2].astype(np.float32) / 255.0)
        acc.hue_sin += float((np.sin(hh) * wgt).sum())
        acc.hue_cos += float((np.cos(hh) * wgt).sum())
        acc.hue_w += float(wgt.sum())
        edges = cv2.Canny(gray, 80, 160)
        acc.edges.append(float(np.count_nonzero(edges)) / edges.size)
        if len(acc.pix) < acc.max_pix_frames:
            acc.pix.append(cv2.resize(small, (32, 18), interpolation=cv2.INTER_AREA).reshape(-1, 3))
        elif np.random.random() < acc.max_pix_frames / (acc.n_sampled + 1):
            acc.pix[np.random.randint(len(acc.pix))] = cv2.resize(small, (32, 18), interpolation=cv2.INTER_AREA).reshape(-1, 3)
        acc.n_sampled += 1
        sec = int(idx / fps)
        traj_bright.setdefault(sec, []).append(bright)
        traj_sat.setdefault(sec, []).append(sat)
        if cfg.flow:
            if acc.prev_gray is not None:
                flow = cv2.calcOpticalFlowFarneback(acc.prev_gray, gray, None, 0.5, 3, 15, 3, 5, 1.2, 0)
                dx, dy, scale, cam, inf, cr = _global_motion(flow, acc.prev_gray)
                norm = 1.0 / (fw * stride)      # -> fraction of frame width per source frame
                acc.cam.append(cam * norm)
                acc.inframe.append(inf * norm)
                acc.total.append((cam + inf) * norm)
                acc.dx.append(dx * norm)
                acc.dy.append(dy * norm)
                acc.zoom.append((scale - 1.0) / stride)
                acc.center_ratio.append(cr)
                traj_motion.setdefault(sec, []).append(acc.total[-1])
            acc.prev_gray = gray

    results = []
    for acc, (s, e, tin, tout) in zip(accs, shots):
        dur_f = e - s
        hue = None
        if acc.hue_w > 0:
            hue = (math.degrees(math.atan2(acc.hue_sin, acc.hue_cos)) + 360.0) % 360.0
        sat_mean = float(np.mean(acc.sat)) if acc.sat else 0.0
        pix = np.concatenate(acc.pix) if acc.pix else np.zeros((0, 3), np.uint8)
        colors = dominant_colors(pix, 5)
        if acc.cam:
            cam = float(np.mean(acc.cam)); inf = float(np.mean(acc.inframe)); tot = float(np.mean(acc.total))
            mdx = float(np.mean(acc.dx)); mdy = float(np.mean(acc.dy)); mz = float(np.mean(acc.zoom))
            vec = np.array([acc.dx, acc.dy]).T
            mags = np.linalg.norm(vec, axis=1)
            # directional coherence: |mean vector| / mean |vector|  (1 = steady, 0 = random)
            coh = float(np.linalg.norm(vec.mean(axis=0)) / (mags.mean() + 1e-9)) if len(vec) > 1 else 1.0
            jitter = round(1.0 - min(1.0, coh), 3)
            cr = float(np.median(acc.center_ratio))
            zs = np.array(acc.zoom)
            mz_med = float(np.median(zs))
            zoom_coh = float(abs(np.sign(zs).mean())) if len(zs) else 0.0
            cam_type = classify_camera_motion(cam, inf, mdx, mdy, mz_med, jitter, cr, zoom_coh)
        else:
            cam = inf = tot = mdx = mdy = mz = jitter = 0.0
            cam_type = None            # no flow computed (flow disabled, or shot too short to sample twice)
        frames = [acc.saved[k] for k in sorted(acc.saved)]
        results.append({
            "idx": acc.idx, "start_frame": s, "end_frame": e, "duration_frames": dur_f,
            "start_sec": s / fps, "end_sec": e / fps, "duration_sec": dur_f / fps, "fps": fps,
            "in_type": tin, "out_type": tout,
            "brightness": round(float(np.mean(acc.bright)), 4) if acc.bright else None,
            "contrast": round(float(np.mean(acc.contrast)), 4) if acc.contrast else None,
            "saturation": round(sat_mean, 4),
            "colors": colors,
            "hue_deg": round(hue, 1) if hue is not None else None,
            "hue_name": hue_name(hue, sat_mean),
            "motion_camera": round(cam, 5), "motion_inframe": round(inf, 5), "motion_total": round(tot, 5),
            "cam_dx": round(mdx, 5), "cam_dy": round(mdy, 5), "cam_zoom": round(mz, 5), "cam_jitter": round(jitter, 3),
            "camera_motion": cam_type,
            "complexity_edges": round(float(np.mean(acc.edges)), 4) if acc.edges else None,
            "complexity_jpeg": round(acc.jpeg_complexity, 4) if acc.jpeg_complexity is not None else None,
            "phash": acc.phash,
            "key_frame": acc.key_path, "frames": frames,
        })
    def _traj(d: dict[int, list[float]]) -> list[float | None]:
        if not d:
            return []
        n = max(d) + 1
        return [round(float(np.mean(d[i])), 4) if i in d else None for i in range(n)]
    traj = {"brightness_1hz": _traj(traj_bright), "saturation_1hz": _traj(traj_sat), "motion_1hz": _traj(traj_motion)}
    return results, traj
