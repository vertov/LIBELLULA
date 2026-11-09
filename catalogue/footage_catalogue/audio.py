"""Layer 2: the audio timeline, independent of picture cuts.

* loudness (ffmpeg ebur128): integrated LUFS, LRA, true/sample peak, 1 Hz short-term envelope
* silence spans (ffmpeg silencedetect)
* segmentation + tagging: 2 s windows / 1 s hop, PANNs CNN14 (AudioSet, 527 classes) grouped into
  speech | music | ambience | sfx | silence, smoothed and merged into segments
* transcription with faster-whisper (word timestamps, language id)
* per-shot audio summary and audio-across-cut flags
"""
from __future__ import annotations

import re
import subprocess
import urllib.request
from pathlib import Path

import numpy as np
import soundfile as sf

from .config import Config
from .log import log

SILENCE_DB = -50.0          # window RMS below this => silence (dBFS)
WIN_SEC, HOP_SEC = 2.0, 1.0

# AudioSet (527-class PANNs ordering) index groups
_SPEECH_IDX = set(range(0, 16)) | {16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 68, 70}
_MUSIC_IDX = set(range(137, 283)) | set(range(27, 36)) | {36}
_AMBIENCE_IDX = set(range(283, 300)) | {300, 301, 302, 327, 343, 496, 506, 507, 508, 509, 510, 511, 512, 513, 514,
                                        515, 516, 517, 518, 519, 520, 521, 522, 523, 526} | set(range(72, 137)) | {69}
_SILENCE_IDX = {500}


def coarse_of(idx: int) -> str:
    if idx in _SPEECH_IDX:
        return "speech"
    if idx in _MUSIC_IDX:
        return "music"
    if idx in _SILENCE_IDX:
        return "silence"
    if idx in _AMBIENCE_IDX:
        return "ambience"
    return "sfx"


# ---------------------------------------------------------------------------
# ffmpeg loudness + silence (one pass over the source's audio stream)
# ---------------------------------------------------------------------------

_RE_T = re.compile(r"t:\s*([\d.]+)\s+TARGET:.*?M:\s*(-?[\d.]+|-inf)\s+S:\s*(-?[\d.]+|-inf)\s+I:\s*(-?[\d.]+|-inf)")
_RE_SIL_START = re.compile(r"silence_start:\s*([\d.]+)")
_RE_SIL_END = re.compile(r"silence_end:\s*([\d.]+)\s*\|\s*silence_duration:\s*([\d.]+)")


def loudness_and_silence(src: Path, duration: float, silence_db: float = -45.0, min_silence: float = 0.5) -> dict:
    cmd = ["ffmpeg", "-nostdin", "-v", "info", "-i", str(src), "-map", "0:a:0", "-vn",
           "-af", f"ebur128=peak=true+sample,silencedetect=n={silence_db}dB:d={min_silence}", "-f", "null", "-"]
    proc = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    txt = proc.stderr
    env: dict[int, list[float]] = {}
    for m in _RE_T.finditer(txt):
        t = float(m.group(1))
        s = m.group(3)
        if s != "-inf":
            env.setdefault(int(t), []).append(float(s))
    envelope = [round(float(np.mean(env[i])), 1) if i in env else None for i in range(int(duration) + 1)] if env else []
    spans = []
    starts = [float(m.group(1)) for m in _RE_SIL_START.finditer(txt)]
    ends = [(float(m.group(1)), float(m.group(2))) for m in _RE_SIL_END.finditer(txt)]
    for i, st in enumerate(starts):
        if i < len(ends):
            spans.append([round(st, 3), round(ends[i][0], 3)])
        else:
            spans.append([round(st, 3), round(duration, 3)])

    def grab(pattern):
        m = re.search(pattern, txt)
        return float(m.group(1)) if m and m.group(1) != "-inf" else None

    summary_start = txt.rfind("Summary:")
    tail = txt[summary_start:] if summary_start >= 0 else txt
    def grab_tail(pattern):
        m = re.search(pattern, tail)
        return float(m.group(1)) if m and m.group(1) != "-inf" else None
    return {
        "integrated_lufs": grab_tail(r"Integrated loudness:\s*I:\s*(-?[\d.]+|-inf)"),
        "loudness_range": grab_tail(r"LRA:\s*(-?[\d.]+)\s*LU"),
        "sample_peak_dbfs": grab_tail(r"Sample peak:\s*Peak:\s*(-?[\d.]+|-inf)"),
        "true_peak_dbtp": grab_tail(r"True peak:\s*Peak:\s*(-?[\d.]+|-inf)"),
        "silence_spans": spans,
        "envelope_1hz": envelope,
    }


# ---------------------------------------------------------------------------
# PANNs tagger
# ---------------------------------------------------------------------------

_PANNS = None
PANNS_URL = "https://zenodo.org/record/3987831/files/Cnn14_mAP%3D0.431.pth?download=1"


def load_panns(models_dir: Path):
    global _PANNS
    if _PANNS is None:
        from panns_inference import AudioTagging
        ckpt = models_dir / "panns" / "Cnn14_mAP=0.431.pth"
        if not ckpt.exists() or ckpt.stat().st_size < 3e8:
            ckpt.parent.mkdir(parents=True, exist_ok=True)
            log.info("downloading PANNs CNN14 checkpoint (~330 MB) to %s", ckpt)
            urllib.request.urlretrieve(PANNS_URL, ckpt)
        _PANNS = AudioTagging(checkpoint_path=str(ckpt), device="cpu")
    return _PANNS


def _windows(wav: Path, sr_expected: int = 32000):
    """Yield (start_sec, window_float32) 2 s windows at 1 s hop, streaming from disk."""
    with sf.SoundFile(str(wav)) as f:
        sr = f.samplerate
        hop = int(HOP_SEC * sr)
        win = int(WIN_SEC * sr)
        prev = np.zeros(0, dtype=np.float32)
        pos = 0
        while True:
            block = f.read(hop, dtype="float32", always_2d=False)
            if block.ndim > 1:
                block = block.mean(axis=1)
            if len(block) == 0:
                break
            buf = np.concatenate([prev, block])
            if len(buf) < win:
                buf = np.pad(buf, (0, win - len(buf)))
            start = max(0.0, pos / sr - (WIN_SEC - HOP_SEC)) if pos else 0.0
            yield start, buf[-win:], sr
            prev = buf[-(win - hop):] if win > hop else np.zeros(0, dtype=np.float32)
            pos += len(block)
            if len(block) < hop:
                break


def tag_windows(wav: Path, cfg: Config, use_tagger: bool) -> list[dict]:
    """Per 1 s hop: rms_db, coarse scores, top fine labels."""
    tagger = None
    labels = None
    if use_tagger:
        try:
            tagger = load_panns(cfg.models_dir)
            labels = tagger.labels
        except Exception as e:
            log.warning("PANNs unavailable (%s); audio segmentation falls back to energy only", e)
    out = []
    batch, meta = [], []

    def flush():
        if not batch:
            return
        x = np.stack(batch)
        clip, _ = tagger.inference(x)
        for probs, (start, rms) in zip(clip, meta):
            groups = {"speech": 0.0, "music": 0.0, "ambience": 0.0, "sfx": 0.0, "silence": 0.0}
            for i, p in enumerate(probs):
                g = coarse_of(i)
                groups[g] = max(groups[g], float(p))
            top = np.argsort(-probs)[:5]
            out.append({"start": start, "rms_db": rms, "groups": groups,
                        "top": [{"label": labels[i], "idx": int(i), "score": round(float(probs[i]), 3)} for i in top]})
        batch.clear(); meta.clear()

    for start, x, sr in _windows(wav):
        rms = float(np.sqrt(np.mean(x ** 2)) + 1e-9)
        rms_db = 20 * np.log10(rms)
        if tagger is None:
            out.append({"start": start, "rms_db": rms_db, "groups": None, "top": []})
            continue
        batch.append(x); meta.append((start, rms_db))
        if len(batch) >= 16:
            flush()
    flush()
    return out


def windows_to_segments(windows: list[dict], duration: float) -> list[dict]:
    """Label each hop, smooth, merge into segments."""
    if not windows:
        return []
    labs = []
    for w in windows:
        if w["rms_db"] < SILENCE_DB:
            labs.append("silence")
        elif w["groups"] is None:
            labs.append("sound")
        else:
            g = dict(w["groups"])
            g.pop("silence", None)
            # speech gets a modest priority: it matters most for editing
            if g["speech"] >= 0.25 and g["speech"] >= 0.6 * max(g.values()):
                labs.append("speech")
            else:
                best = max(g, key=g.get)
                labs.append(best if g[best] >= 0.08 else "ambience")
    # median-style smoothing: a single-window island between equal labels takes its neighbours' label
    for i in range(1, len(labs) - 1):
        if labs[i - 1] == labs[i + 1] != labs[i]:
            labs[i] = labs[i - 1]
    segs = []
    for i, (w, lab) in enumerate(zip(windows, labs)):
        start = w["start"] if i == 0 else i * HOP_SEC
        end = min(duration, (i + 1) * HOP_SEC) if i < len(windows) - 1 else duration
        if segs and segs[-1]["coarse"] == lab:
            segs[-1]["end"] = end
            segs[-1]["rms"].append(w["rms_db"])
            segs[-1]["wins"].append(w)
        else:
            segs.append({"coarse": lab, "start": start, "end": end, "rms": [w["rms_db"]], "wins": [w]})
    # absorb segments shorter than 1.5 s into the longer neighbour (except silence, which can be short)
    changed = True
    while changed and len(segs) > 1:
        changed = False
        for i, s in enumerate(segs):
            if s["end"] - s["start"] < 1.5 and s["coarse"] != "silence":
                nb = i - 1 if i > 0 and (i == len(segs) - 1 or (segs[i - 1]["end"] - segs[i - 1]["start"]) >= (segs[i + 1]["end"] - segs[i + 1]["start"])) else i + 1
                tgt = segs[nb]
                tgt["start"] = min(tgt["start"], s["start"]); tgt["end"] = max(tgt["end"], s["end"])
                tgt["rms"] += s["rms"]; tgt["wins"] += s["wins"]
                segs.pop(i); changed = True
                break
    out = []
    for i, s in enumerate(segs):
        fine: dict[str, list[float]] = {}
        conf = []
        for w in s["wins"]:
            for t in w["top"]:
                fine.setdefault(t["label"], []).append(t["score"])
            if w["groups"] and s["coarse"] in w["groups"]:
                conf.append(w["groups"][s["coarse"]])
        fine_sorted = sorted(((k, float(np.mean(v)) * len(v) / len(s["wins"])) for k, v in fine.items()), key=lambda kv: -kv[1])[:4]
        out.append({"idx": i, "start_sec": round(s["start"], 3), "end_sec": round(s["end"], 3),
                    "duration_sec": round(s["end"] - s["start"], 3), "coarse": s["coarse"],
                    "labels": [{"label": k, "score": round(v, 3)} for k, v in fine_sorted],
                    "rms_db": round(float(np.mean(s["rms"])), 1),
                    "confidence": round(float(np.mean(conf)), 3) if conf else None})
    return out


# ---------------------------------------------------------------------------
# Whisper
# ---------------------------------------------------------------------------

_WHISPER = None


def load_whisper(cfg: Config):
    global _WHISPER
    if _WHISPER is None:
        from faster_whisper import WhisperModel
        device = cfg.whisper_device
        if device == "auto":
            device = "cpu"
            try:
                import torch
                if torch.cuda.is_available():
                    device = "cuda"
            except Exception:
                pass
        compute = "int8" if device == "cpu" else "float16"
        _WHISPER = WhisperModel(cfg.whisper_model, device=device, compute_type=compute)
    return _WHISPER


def _read_chunks_16k(wav: Path, chunk_sec: float, overlap_sec: float):
    """Yield (offset_sec, float32 mono 16 kHz) chunks, streaming from disk (never the whole file)."""
    from scipy.signal import resample_poly
    with sf.SoundFile(str(wav)) as f:
        sr = f.samplerate
        step = int(chunk_sec * sr)
        ov = int(overlap_sec * sr)
        pos = 0
        while pos < f.frames:
            f.seek(pos)
            x = f.read(step + ov, dtype="float32", always_2d=False)
            if x.ndim > 1:
                x = x.mean(axis=1)
            if len(x) == 0:
                break
            if sr != 16000:
                from math import gcd
                g = gcd(16000, sr)
                x = resample_poly(x, 16000 // g, sr // g).astype(np.float32)
            yield pos / sr, x
            pos += step


def transcribe(wav: Path, cfg: Config, chunk_sec: float = 600.0, overlap_sec: float = 2.0) -> tuple[list[dict], str | None, float | None]:
    """faster-whisper with word timestamps.  Audio is fed as 16 kHz arrays in 10-minute chunks
    (avoids PyAV version issues and keeps memory bounded); segments starting inside the
    overlap of the previous chunk are dropped."""
    model = load_whisper(cfg)
    out: list[dict] = []
    lang, lang_p = None, None
    last_end = -1.0
    for offset, x in _read_chunks_16k(wav, chunk_sec, overlap_sec):
        if float(np.abs(x).max(initial=0.0)) < 1e-4:
            continue
        segments, info = model.transcribe(x, language=lang, word_timestamps=True, vad_filter=True,
                                          vad_parameters={"min_silence_duration_ms": 500}, beam_size=5)
        if lang is None:
            lang, lang_p = info.language, round(float(info.language_probability), 3)
        for s in segments:
            st = s.start + offset
            if st < last_end - 0.05 and offset > 0:
                continue                      # already covered by the previous chunk
            words = [{"w": w.word.strip(), "s": round(float(w.start + offset), 3), "e": round(float(w.end + offset), 3),
                      "p": round(float(w.probability), 3)} for w in (s.words or [])]
            out.append({"idx": len(out), "start_sec": round(float(st), 3), "end_sec": round(float(s.end + offset), 3),
                        "text": s.text.strip(), "language": info.language, "words": words,
                        "avg_logprob": round(float(s.avg_logprob), 3), "no_speech_prob": round(float(s.no_speech_prob), 3)})
            last_end = s.end + offset
    return out, lang, lang_p


def relabel_with_transcript(segments: list[dict], transcript: list[dict]) -> None:
    """Energy-only fallback: windows the transcriber found speech in become 'speech'."""
    for s in segments:
        if s["coarse"] != "sound":
            continue
        cover = 0.0
        for t in transcript:
            cover += max(0.0, min(s["end_sec"], t["end_sec"]) - max(s["start_sec"], t["start_sec"]))
        s["coarse"] = "speech" if cover > 0.4 * s["duration_sec"] else "ambience"


# ---------------------------------------------------------------------------
# Shot-level summary
# ---------------------------------------------------------------------------

def summarise_for_shots(shots: list[dict], segments: list[dict], transcript: list[dict], bridge_margin: float = 0.4) -> None:
    """Fill audio_class, *_frac, bridge flags and transcript_text on each shot dict (in place)."""
    words = [w for t in transcript for w in t["words"]] if transcript else []
    for sh in shots:
        a, b = sh["start_sec"], sh["end_sec"]
        dur = max(1e-6, b - a)
        frac = {"speech": 0.0, "music": 0.0, "ambience": 0.0, "sfx": 0.0, "silence": 0.0, "sound": 0.0}
        for s in segments:
            ov = max(0.0, min(b, s["end_sec"]) - max(a, s["start_sec"]))
            if ov > 0:
                frac[s["coarse"]] = frac.get(s["coarse"], 0.0) + ov / dur
        if not segments:
            sh["audio_class"] = "none"
        else:
            best = max(frac, key=frac.get)
            sh["audio_class"] = best if frac[best] >= 0.6 else "mixed"
        sh["speech_frac"] = round(frac["speech"], 3)
        sh["music_frac"] = round(frac["music"], 3)
        sh["silence_frac"] = round(frac["silence"], 3)

        def bridges(t: float, items: list[dict]) -> int:
            for s in items:
                if s["start_sec"] <= t - bridge_margin and s["end_sec"] >= t + bridge_margin and s.get("coarse") != "silence":
                    return 1
            return 0
        non_sil = [s for s in segments if s["coarse"] != "silence"]
        sh["audio_bridge_in"] = bridges(a, non_sil) if sh["in_type"] != "start" else 0
        sh["audio_bridge_out"] = bridges(b, non_sil) if sh["out_type"] != "end" else 0
        sh["speech_bridge_in"] = bridges(a, transcript) if sh["in_type"] != "start" else 0
        sh["speech_bridge_out"] = bridges(b, transcript) if sh["out_type"] != "end" else 0
        if words:
            sh["transcript_text"] = " ".join(w["w"] for w in words if a <= (w["s"] + w["e"]) / 2 < b) or None
        else:
            sh["transcript_text"] = None
