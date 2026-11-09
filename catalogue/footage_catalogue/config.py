"""Run configuration and output layout.

Everything the pipeline writes goes under ``out_root``.  The source tree is
never written to.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field, asdict
from pathlib import Path

VIDEO_EXTS = {".mp4", ".mov", ".m4v", ".mkv", ".avi", ".mxf", ".mts", ".m2ts",
              ".mpg", ".mpeg", ".webm", ".wmv", ".flv", ".dv", ".3gp", ".ts", ".vob", ".ogv"}


@dataclass
class Config:
    source_root: Path
    out_root: Path

    # --- which passes run -------------------------------------------------
    audio: bool = True            # Layer 2 (loudness, silence, segmentation)
    tagger: bool = True           # PANNs sound tagging (slow-ish, needs torch)
    transcribe: bool = True       # Whisper (slow)
    vision: bool = False          # Layer 3 model pass during `run` (also runnable later with `fcat vision`)
    embed: bool = True            # CLIP embedding (part of Layer 3)
    faces: bool = True            # face detection (part of Layer 3)
    people: bool = False          # YOLO person count (optional extra, part of Layer 3)
    describe: str = "off"         # off | smolvlm | claude  (part of Layer 3)
    flow: bool = True             # optical flow in Layer 1 (the slowest Layer 1 item)
    html: bool = True             # regenerate HTML after each file

    # --- detection ----------------------------------------------------------
    detector: str = "auto"        # auto | transnetv2 | pyscenedetect
    transnet_threshold: float = 0.5
    psd_threshold: float = 27.0   # PySceneDetect ContentDetector threshold
    min_shot_frames: int = 2
    edl_dir: Path | None = None   # look for <stem>.edl here (and next to the source)
    edl_use_record: bool = False  # use record TCs (relative to first event) instead of source TCs

    # --- resource caps -----------------------------------------------------
    proxy_height: int = 480
    analysis_stride: int = 2      # analyse every Nth proxy frame for colour/flow
    flow_width: int = 320         # optical flow computed at this width
    strip_frames: int = 4         # filmstrip frames per shot (2 for very short shots)
    thumb_width: int = 320
    vision_min_shot_sec: float = 0.5
    vision_frames_per_shot: int = 2   # 1 or 2 sampled frames for the model pass
    whisper_model: str = "small"
    whisper_device: str = "auto"
    clip_model: str = "ViT-B-32"
    clip_pretrained: str = "laion2b_s34b_b79k"
    vlm_model: str = "HuggingFaceTB/SmolVLM-500M-Instruct"
    claude_model: str = "claude-opus-5-5"
    keep_proxies: bool = True
    hwaccel: str = "auto"         # auto (VideoToolbox on macOS) | none | <ffmpeg hwaccel>
    force: bool = False           # redo layers already marked done
    limit: int | None = None      # process at most N files this run
    max_files_for_eta: int = 3

    # --- derived paths ------------------------------------------------------
    @property
    def db_path(self) -> Path: return self.out_root / "catalogue.sqlite"
    @property
    def proxies_dir(self) -> Path: return self.out_root / "proxies"
    @property
    def thumbs_dir(self) -> Path: return self.out_root / "thumbs"
    @property
    def json_dir(self) -> Path: return self.out_root / "json"
    @property
    def md_dir(self) -> Path: return self.out_root / "markdown"
    @property
    def html_dir(self) -> Path: return self.out_root / "html"
    @property
    def logs_dir(self) -> Path: return self.out_root / "logs"
    @property
    def models_dir(self) -> Path: return self.out_root / "models"

    def ensure_dirs(self) -> None:
        for d in (self.out_root, self.proxies_dir, self.thumbs_dir, self.json_dir,
                  self.md_dir, self.html_dir, self.logs_dir, self.models_dir):
            d.mkdir(parents=True, exist_ok=True)
        # Hard guard: never write inside the source tree.
        try:
            self.out_root.resolve().relative_to(self.source_root.resolve())
            raise SystemExit("Refusing to run: output root is inside the source root.")
        except ValueError:
            pass

    def to_json(self) -> str:
        d = asdict(self)
        for k, v in d.items():
            if isinstance(v, Path):
                d[k] = str(v)
        return json.dumps(d, indent=2, default=str)


def is_video(p: Path) -> bool:
    return p.suffix.lower() in VIDEO_EXTS and not p.name.startswith("._") and not p.name.startswith(".")


def scan_sources(root: Path) -> list[Path]:
    """Recursively list video files under ``root`` (sorted, stable)."""
    root = Path(root)
    if root.is_file():
        return [root] if is_video(root) else []
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for fn in sorted(filenames):
            p = Path(dirpath) / fn
            if is_video(p):
                out.append(p)
    return out
