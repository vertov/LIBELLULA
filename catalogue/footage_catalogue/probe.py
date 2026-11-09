"""ffprobe wrapper and timecode helpers."""
from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from fractions import Fraction
from pathlib import Path


@dataclass
class ProbeInfo:
    path: Path
    duration: float
    fps: float
    fps_num: int
    fps_den: int
    width: int
    height: int
    codec: str
    nb_frames: int | None
    start_timecode: str | None      # SMPTE from container/stream tags, if any
    vfr: bool
    has_audio: bool
    audio_channels: int
    audio_layout: str
    audio_sample_rate: int
    audio_codec: str
    size_bytes: int
    raw: dict = field(default_factory=dict, repr=False)


def _frac(s: str) -> Fraction | None:
    try:
        if "/" in s:
            n, d = s.split("/")
            if int(d) == 0:
                return None
            return Fraction(int(n), int(d))
        return Fraction(s)
    except Exception:
        return None


def probe(path: Path) -> ProbeInfo:
    cmd = ["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", str(path)]
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    data = json.loads(out)
    v = next((s for s in data["streams"] if s.get("codec_type") == "video" and s.get("disposition", {}).get("attached_pic", 0) == 0), None)
    if v is None:
        raise ValueError(f"no video stream in {path}")
    a = next((s for s in data["streams"] if s.get("codec_type") == "audio"), None)
    fmt = data.get("format", {})

    r = _frac(v.get("r_frame_rate", "0/0")) or Fraction(25)
    avg = _frac(v.get("avg_frame_rate", "0/0")) or r
    # r_frame_rate is the container's nominal rate; for CFR files it equals avg_frame_rate.
    vfr = abs(float(r) - float(avg)) > 0.01 if avg else False
    fps_frac = r if not vfr else avg
    # Normalise common NTSC rates to their exact rationals.
    for num, den in ((24000, 1001), (30000, 1001), (60000, 1001), (48000, 1001)):
        if abs(float(fps_frac) - num / den) < 1e-3:
            fps_frac = Fraction(num, den)
    duration = float(fmt.get("duration") or v.get("duration") or 0.0)
    nb = v.get("nb_frames")
    nb_frames = int(nb) if nb and nb.isdigit() else None
    if nb_frames is None and duration:
        nb_frames = int(round(duration * float(fps_frac)))
    tc = (v.get("tags", {}) or {}).get("timecode") or (fmt.get("tags", {}) or {}).get("timecode")
    if not tc:
        d = next((s for s in data["streams"] if s.get("codec_type") == "data" and (s.get("tags") or {}).get("timecode")), None)
        if d:
            tc = d["tags"]["timecode"]
    return ProbeInfo(
        path=Path(path), duration=duration, fps=float(fps_frac),
        fps_num=fps_frac.numerator, fps_den=fps_frac.denominator,
        width=int(v.get("width", 0)), height=int(v.get("height", 0)),
        codec=v.get("codec_name", ""), nb_frames=nb_frames, start_timecode=tc, vfr=vfr,
        has_audio=a is not None,
        audio_channels=int(a.get("channels", 0)) if a else 0,
        audio_layout=(a.get("channel_layout") or (f"{a.get('channels')}ch" if a else "")) if a else "",
        audio_sample_rate=int(a.get("sample_rate", 0)) if a else 0,
        audio_codec=a.get("codec_name", "") if a else "",
        size_bytes=int(fmt.get("size") or Path(path).stat().st_size),
        raw=data,
    )


# ---------------------------------------------------------------------------
# Timecode helpers (non-drop-frame; frame numbers are the authoritative record)
# ---------------------------------------------------------------------------

def tc_to_frames(tc: str, fps: float) -> int:
    """'HH:MM:SS:FF' (or ';' drop-frame separator, treated as NDF) -> frame count."""
    parts = tc.replace(";", ":").replace(".", ":").split(":")
    if len(parts) != 4:
        raise ValueError(f"bad timecode {tc!r}")
    h, m, s, f = (int(p) for p in parts)
    nominal = int(round(fps))
    return ((h * 60 + m) * 60 + s) * nominal + f


def frames_to_tc(frame: int, fps: float) -> str:
    nominal = max(1, int(round(fps)))
    f = frame % nominal
    total_s = frame // nominal
    h, r = divmod(total_s, 3600)
    m, s = divmod(r, 60)
    return f"{h:02d}:{m:02d}:{s:02d}:{f:02d}"


def sec_to_hms(sec: float) -> str:
    ms = int(round((sec - int(sec)) * 1000))
    sec = int(sec)
    h, r = divmod(sec, 3600)
    m, s = divmod(r, 60)
    return f"{h:02d}:{m:02d}:{s:02d}.{ms:03d}"
