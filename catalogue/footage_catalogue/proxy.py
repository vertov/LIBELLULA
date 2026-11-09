"""480p proxy and audio extraction with ffmpeg.

The proxy keeps the source frame rate and frame count (constant-frame-rate
output at the native rate), so proxy frame index == source frame index and
every cut found on the proxy maps back to a frame-accurate source timecode.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from .probe import ProbeInfo
from .log import log


def make_proxy(info: ProbeInfo, dst: Path, height: int = 480, force: bool = False, hwaccel: str = "auto") -> Path:
    """Encode the 480p proxy.  ``hwaccel``: auto (VideoToolbox on macOS) | none | <ffmpeg hwaccel name>.

    Hardware decode is tried first for 4K sources and falls back to software if ffmpeg fails."""
    if dst.exists() and not force:
        return dst
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_suffix(".tmp.mp4")
    rate = f"{info.fps_num}/{info.fps_den}"
    vf = f"scale=-2:{height}:flags=bicubic" if info.height > height else "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    if hwaccel == "auto":
        hwaccel = "videotoolbox" if sys.platform == "darwin" else "none"
    # CFR sources: pass every frame through unchanged so proxy frame i == source frame i.
    # VFR sources (phones): resample to a constant rate so frame index * fps is the true time.
    fps_mode = ["-fps_mode", "cfr", "-r", rate] if info.vfr else ["-fps_mode", "passthrough"]
    attempts = []
    if hwaccel and hwaccel != "none":
        attempts.append(["-hwaccel", hwaccel])
    attempts.append([])
    last_err = None
    for hw in attempts:
        cmd = ["ffmpeg", "-v", "error", "-y", "-nostdin", *hw, "-i", str(info.path),
               "-map", "0:v:0", "-an", "-sn", "-dn",
               "-vf", vf, *fps_mode,
               "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-g", "25",
               "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(tmp)]
        log.debug("ffmpeg proxy: %s", " ".join(cmd))
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode == 0 and tmp.exists() and tmp.stat().st_size > 0:
            tmp.replace(dst)
            return dst
        last_err = proc.stderr.strip()[-500:]
        if hw:
            log.warning("hardware decode (%s) failed for %s; retrying in software", hw[1], info.path.name)
    raise RuntimeError(f"ffmpeg proxy failed for {info.path}: {last_err}")


def extract_audio(info: ProbeInfo, dst: Path, sample_rate: int = 32000, force: bool = False) -> Path | None:
    """Mono WAV at ``sample_rate`` (32 kHz suits PANNs; Whisper resamples itself)."""
    if not info.has_audio:
        return None
    if dst.exists() and not force:
        return dst
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_suffix(".tmp.wav")
    cmd = ["ffmpeg", "-v", "error", "-y", "-nostdin", "-i", str(info.path), "-map", "0:a:0", "-vn",
           "-ac", "1", "-ar", str(sample_rate), "-c:a", "pcm_s16le", str(tmp)]
    subprocess.run(cmd, check=True)
    tmp.replace(dst)
    return dst


def count_frames(path: Path) -> int:
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_packets",
                          "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", str(path)],
                         capture_output=True, text=True).stdout.strip()
    return int(out) if out.isdigit() else -1
