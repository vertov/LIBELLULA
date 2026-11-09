"""Layer 4: per-file derived statistics and a rule-based editorial paragraph."""
from __future__ import annotations

from collections import Counter

import numpy as np

from .probe import sec_to_hms

HIST_EDGES = [0, 0.5, 1, 2, 4, 8, 16, 32, float("inf")]
HIST_LABELS = ["<0.5s", "0.5-1s", "1-2s", "2-4s", "4-8s", "8-16s", "16-32s", ">32s"]


def duration_histogram(durs: list[float]) -> dict:
    counts = [0] * (len(HIST_EDGES) - 1)
    for d in durs:
        for i in range(len(HIST_EDGES) - 1):
            if HIST_EDGES[i] <= d < HIST_EDGES[i + 1]:
                counts[i] += 1
                break
    return {"labels": HIST_LABELS, "counts": counts}


def cut_timeline(shots: list[dict], duration: float, window: float = 30.0) -> dict:
    cuts = [round(s["start_sec"], 3) for s in shots[1:]]
    n_bins = max(1, int(np.ceil(duration / window)))
    rate = [0] * n_bins
    for c in cuts:
        rate[min(n_bins - 1, int(c // window))] += 1
    return {"cuts_sec": cuts, "window_sec": window, "cuts_per_window": rate,
            "shot_lengths": [round(s["duration_sec"], 3) for s in shots]}


def shot_trajectories(shots: list[dict]) -> dict:
    keys = ("brightness", "saturation", "contrast", "motion_total", "motion_camera", "motion_inframe", "complexity_edges")
    out = {k: [s.get(k) for s in shots] for k in keys}
    out["hue_deg"] = [s.get("hue_deg") for s in shots]
    out["dominant_hex"] = [(s.get("colors") or [{}])[0].get("hex") if s.get("colors") else None for s in shots]
    out["start_sec"] = [round(s["start_sec"], 3) for s in shots]
    return out


def _pct(x: float) -> str:
    return f"{int(round(100 * x))}%"


def summarise(file: dict, shots: list[dict], segments: list[dict], transcript: list[dict]) -> dict:
    durs = [s["duration_sec"] for s in shots]
    n = len(shots)
    dur = file["duration_sec"]
    stats = {
        "shot_count": n,
        "mean_shot_sec": round(float(np.mean(durs)), 3) if durs else None,
        "median_shot_sec": round(float(np.median(durs)), 3) if durs else None,
        "min_shot_sec": round(float(np.min(durs)), 3) if durs else None,
        "max_shot_sec": round(float(np.max(durs)), 3) if durs else None,
        "cuts_per_minute": round((n - 1) / (dur / 60.0), 2) if dur else None,
        "duration_hist": duration_histogram(durs),
        "cut_timeline": cut_timeline(shots, dur),
        "trajectories": shot_trajectories(shots),
    }
    stats["summary"] = paragraph(file, shots, segments, transcript, stats)
    return stats


def paragraph(file: dict, shots: list[dict], segments: list[dict], transcript: list[dict], st: dict) -> str:
    n = len(shots)
    dur = file["duration_sec"]
    if n == 0:
        return "No shots detected."
    parts = []
    hms = sec_to_hms(dur)[:-4]
    parts.append(f"{n} shot{'s' if n != 1 else ''} over {hms} "
                 f"(mean {st['mean_shot_sec']:.1f} s, median {st['median_shot_sec']:.1f} s, "
                 f"{st['cuts_per_minute'] or 0:.1f} cuts/min).")
    # rhythm
    durs = np.array([s["duration_sec"] for s in shots])
    if n >= 4:
        cv = float(durs.std() / (durs.mean() + 1e-9))
        rhythm = "very even" if cv < 0.35 else "fairly regular" if cv < 0.7 else "irregular" if cv < 1.2 else "highly uneven"
        short = int((durs < 1.0).sum())
        long_ = int((durs > 10.0).sum())
        bits = [f"Cutting rhythm is {rhythm}"]
        if short:
            bits.append(f"{short} shot{'s' if short != 1 else ''} under 1 s")
        if long_:
            bits.append(f"{long_} over 10 s")
        parts.append("; ".join(bits) + ".")
    # transitions
    types = Counter(s["in_type"] for s in shots[1:])
    tr = []
    if types.get("dissolve"):
        tr.append(f"{types['dissolve']} dissolve{'s' if types['dissolve'] != 1 else ''}")
    if types.get("fade"):
        tr.append(f"{types['fade']} fade{'s' if types['fade'] != 1 else ''}")
    if tr:
        parts.append("Transitions include " + " and ".join(tr) + "; the rest are hard cuts.")
    # camera
    cams = Counter(s.get("camera_motion") for s in shots if s.get("camera_motion"))
    if cams:
        top = cams.most_common(2)
        desc = ", ".join(f"{k} ({_pct(v / n)})" for k, v in top)
        parts.append(f"Camera is mostly {desc}.")
    # scale / place / time (Layer 3, if present)
    scales = Counter(s.get("shot_scale") for s in shots if s.get("shot_scale"))
    if scales:
        parts.append("Shot scale: " + ", ".join(f"{k} {_pct(v / sum(scales.values()))}" for k, v in scales.most_common()) + ".")
    place = Counter(s.get("interior_exterior") for s in shots if s.get("interior_exterior"))
    tod = Counter(s.get("day_night") for s in shots if s.get("day_night"))
    if place or tod:
        bits = []
        if place:
            k, v = place.most_common(1)[0]
            bits.append(f"{_pct(v / sum(place.values()))} {k}")
        if tod:
            k, v = tod.most_common(1)[0]
            bits.append(f"{_pct(v / sum(tod.values()))} {k}")
        parts.append("Setting reads as " + ", ".join(bits) + ".")
    faces = [s.get("face_count") for s in shots if s.get("face_count") is not None]
    if faces:
        with_faces = sum(1 for f in faces if f)
        parts.append(f"Faces appear in {_pct(with_faces / len(faces))} of shots.")
    # look
    b = [s["brightness"] for s in shots if s.get("brightness") is not None]
    sat = [s["saturation"] for s in shots if s.get("saturation") is not None]
    if b and sat:
        mb, ms = float(np.mean(b)), float(np.mean(sat))
        tone = "dark" if mb < 0.3 else "bright" if mb > 0.6 else "mid-toned"
        col = "near-monochrome" if ms < 0.12 else "muted" if ms < 0.3 else "saturated" if ms > 0.5 else "moderately coloured"
        hues = Counter(s.get("hue_name") for s in shots if s.get("hue_name") and s["hue_name"] != "neutral")
        hue_txt = f", leaning {hues.most_common(1)[0][0]}" if hues else ""
        parts.append(f"Overall {tone} and {col}{hue_txt}.")
    mot = [s["motion_total"] for s in shots if s.get("motion_total") is not None]
    if mot:
        mm = float(np.mean(mot))
        parts.append("Motion energy is " + ("low" if mm < 0.003 else "moderate" if mm < 0.012 else "high") + ".")
    # audio
    if not file.get("has_audio"):
        parts.append("No audio track.")
    elif segments:
        tot = sum(s["duration_sec"] for s in segments) or 1.0
        by = Counter()
        for s in segments:
            by[s["coarse"]] += s["duration_sec"]
        parts.append("Sound: " + ", ".join(f"{k} {_pct(v / tot)}" for k, v in by.most_common(3)) + ".")
        if transcript:
            words = sum(len(t["words"]) for t in transcript)
            lang = transcript[0].get("language") or "?"
            parts.append(f"Speech transcribed: ~{words} words ({lang}).")
        bridges = sum(1 for s in shots if s.get("audio_bridge_in"))
        if bridges:
            parts.append(f"Audio runs across {bridges} of {n - 1} cuts.")
    # material note
    if n == 1:
        parts.append("A single continuous take: usable as a long source for sub-clipping.")
    elif st["median_shot_sec"] < 2.0:
        parts.append("Fast-cut material: useful for rhythm and montage, less so for sustained coverage.")
    elif st["median_shot_sec"] > 8.0:
        parts.append("Long takes: good for sustained coverage, establishing and ambience.")
    return " ".join(parts)
