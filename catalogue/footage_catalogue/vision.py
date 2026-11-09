"""Layer 3: optional per-shot model pass, resumable over Layer 1 output.

* CLIP (open_clip ViT-B/32): shot embedding + zero-shot shot scale, interior/exterior, day/night
* faces: OpenCV YuNet (ONNX, downloaded once) with a Haar-cascade fallback
* people count: YOLOv8n (optional extra)
* description + editorial reading: SmolVLM (local) or the Claude API
Camera-motion type is derived from Layer 1 flow statistics and needs no model.
"""
from __future__ import annotations

import base64
import json
import re
import urllib.request
from pathlib import Path

import cv2
import numpy as np

from .config import Config
from .log import log
from .shots import iter_frames

YUNET_URL = ("https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/"
             "face_detection_yunet/face_detection_yunet_2023mar.onnx")

SCALE_PROMPTS = {
    "extreme wide": ["an extreme wide shot of a landscape or cityscape, people tiny or absent",
                     "an establishing shot of a vast space seen from far away"],
    "wide": ["a wide shot showing whole bodies of people and their surroundings",
             "a full shot of a room or street with people seen head to toe"],
    "medium": ["a medium shot of a person framed from the waist up",
               "a shot of one or two people from the chest up, background visible"],
    "close-up": ["a close-up of a face filling the frame", "a close-up of an object or hands filling most of the frame"],
    "extreme close-up": ["an extreme close-up of an eye, mouth or small detail", "a macro shot of a texture or surface"],
}
SCALE_COLLAPSE = {"extreme wide": "wide", "wide": "wide", "medium": "medium", "close-up": "close-up", "extreme close-up": "close-up"}
PLACE_PROMPTS = {"interior": ["a photo taken indoors, inside a room or building"],
                 "exterior": ["a photo taken outdoors, under the open sky"]}
TIME_PROMPTS = {"day": ["a photo taken in daylight"], "night": ["a photo taken at night or in darkness, artificial light"]}


def pick_device() -> str:
    try:
        import torch
        if torch.cuda.is_available():
            return "cuda"
        if getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
            return "mps"
    except Exception:
        pass
    return "cpu"


# ---------------------------------------------------------------------------
# CLIP
# ---------------------------------------------------------------------------

class Clip:
    def __init__(self, cfg: Config):
        import open_clip
        import torch
        self.torch = torch
        self.device = pick_device()
        self.model, _, self.preprocess = open_clip.create_model_and_transforms(cfg.clip_model, pretrained=cfg.clip_pretrained)
        self.model = self.model.eval().to(self.device)
        self.tokenizer = open_clip.get_tokenizer(cfg.clip_model)
        self.name = f"openclip/{cfg.clip_model}/{cfg.clip_pretrained}"
        self.text = {}
        for group, prompts in (("scale", SCALE_PROMPTS), ("place", PLACE_PROMPTS), ("time", TIME_PROMPTS)):
            labels, feats = [], []
            for lab, ps in prompts.items():
                with torch.no_grad():
                    t = self.model.encode_text(self.tokenizer(ps).to(self.device)).float()
                t = t / t.norm(dim=-1, keepdim=True)
                feats.append(t.mean(0))
                labels.append(lab)
            f = torch.stack(feats)
            self.text[group] = (labels, f / f.norm(dim=-1, keepdim=True))

    def embed(self, frames_bgr: list[np.ndarray]) -> np.ndarray:
        from PIL import Image
        imgs = [self.preprocess(Image.fromarray(cv2.cvtColor(f, cv2.COLOR_BGR2RGB))) for f in frames_bgr]
        x = self.torch.stack(imgs).to(self.device)
        with self.torch.no_grad():
            f = self.model.encode_image(x).float()
        f = f / f.norm(dim=-1, keepdim=True)
        v = f.mean(0)
        v = v / v.norm()
        return v.cpu().numpy()

    def zero_shot(self, emb: np.ndarray, group: str) -> dict[str, float]:
        labels, tf = self.text[group]
        e = self.torch.from_numpy(emb).to(self.device)
        logits = (100.0 * e @ tf.T).softmax(dim=-1).cpu().numpy()
        return {l: round(float(p), 4) for l, p in zip(labels, logits)}


# ---------------------------------------------------------------------------
# Faces / people
# ---------------------------------------------------------------------------

class Faces:
    def __init__(self, models_dir: Path):
        self.det = None
        self.haar = None
        onnx = models_dir / "yunet" / "face_detection_yunet_2023mar.onnx"
        try:
            if not onnx.exists() or onnx.stat().st_size < 100_000:
                onnx.parent.mkdir(parents=True, exist_ok=True)
                log.info("downloading YuNet face detector to %s", onnx)
                urllib.request.urlretrieve(YUNET_URL, onnx)
            if onnx.stat().st_size < 100_000:
                raise RuntimeError("YuNet download is not a model file")
            self.det = cv2.FaceDetectorYN.create(str(onnx), "", (320, 320), 0.7, 0.3, 5000)
        except Exception as e:
            log.warning("YuNet unavailable (%s); using Haar cascade", e)
            self.haar = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")

    def detect(self, frame: np.ndarray) -> tuple[int, float]:
        """Return (face_count, largest face height as a fraction of frame height)."""
        h, w = frame.shape[:2]
        if self.det is not None:
            self.det.setInputSize((w, h))
            _, faces = self.det.detect(frame)
            if faces is None or len(faces) == 0:
                return 0, 0.0
            return int(len(faces)), float(max(f[3] for f in faces) / h)
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        faces = self.haar.detectMultiScale(gray, 1.1, 5, minSize=(24, 24))
        if len(faces) == 0:
            return 0, 0.0
        return int(len(faces)), float(max(f[3] for f in faces) / h)


class People:
    def __init__(self, models_dir: Path):
        from ultralytics import YOLO
        models_dir.mkdir(parents=True, exist_ok=True)
        self.model = YOLO(str(models_dir / "yolov8n.pt")) if (models_dir / "yolov8n.pt").exists() else YOLO("yolov8n.pt")

    def count(self, frame: np.ndarray) -> int:
        res = self.model.predict(frame, classes=[0], conf=0.35, verbose=False, imgsz=640)
        return int(len(res[0].boxes)) if res else 0


# ---------------------------------------------------------------------------
# Descriptions
# ---------------------------------------------------------------------------

DESCRIBE_PROMPT = (
    "You are logging footage for a film editor. Look at the frame(s) from one shot. "
    "Reply with exactly two lines. Line 1: one plain sentence describing what is in the shot "
    "(subject, setting, action, framing). Line 2: one sentence on what this shot is useful for as "
    "editing material (e.g. establishing shot, cutaway, reaction, texture, transition, B-roll). "
    "No preamble, no labels."
)
# Small local VLMs cannot follow the two-line instruction; they get one plain question and the
# editorial reading is composed by rule from the description and the measured fields.
SMOL_PROMPT = "Describe this film frame in one sentence: who or what is in it, where, and how it is framed."
_ECHO = re.compile(r"one (plain )?sentence|describe this|film frame", re.I)


def _split_two(text: str) -> tuple[str | None, str | None]:
    lines = [re.sub(r"^(line\s*\d\s*[:.)-]\s*|description\s*:\s*|editorial\s*:\s*|\d+[.)]\s*)", "", l.strip(), flags=re.I)
             for l in text.strip().splitlines() if l.strip()]
    if not lines:
        return None, None
    if len(lines) == 1:
        parts = re.split(r"(?<=[.!?])\s+", lines[0], maxsplit=1)
        return parts[0], (parts[1] if len(parts) > 1 else None)
    return lines[0], lines[1]


class SmolVLM:
    def __init__(self, cfg: Config):
        import torch
        from transformers import AutoProcessor, AutoModelForImageTextToText
        self.torch = torch
        self.device = pick_device()
        dtype = torch.float16 if self.device != "cpu" else torch.float32
        self.processor = AutoProcessor.from_pretrained(cfg.vlm_model)
        self.model = AutoModelForImageTextToText.from_pretrained(cfg.vlm_model, torch_dtype=dtype).to(self.device).eval()
        self.name = cfg.vlm_model

    def describe(self, frames_bgr: list[np.ndarray]) -> tuple[str | None, str | None]:
        """One frame, one short question.  Returns (description, None); the editorial line is rule-based."""
        from PIL import Image
        frame = frames_bgr[len(frames_bgr) // 2]
        img = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        content = [{"type": "image"}, {"type": "text", "text": SMOL_PROMPT}]
        prompt = self.processor.apply_chat_template([{"role": "user", "content": content}], add_generation_prompt=True)
        inputs = self.processor(text=prompt, images=[img], return_tensors="pt").to(self.device)
        with self.torch.no_grad():
            out = self.model.generate(**inputs, max_new_tokens=60, do_sample=False, repetition_penalty=1.1)
        text = self.processor.batch_decode(out[:, inputs["input_ids"].shape[1]:], skip_special_tokens=True)[0].strip()
        text = text.split("\n")[0].strip()
        if not text or _ECHO.search(text):
            return None, None
        if text[-1] not in ".!?":
            text += "."
        return text[0].upper() + text[1:], None


class ClaudeDescriber:
    """Per-shot descriptions through the Claude API (anthropic SDK)."""

    def __init__(self, cfg: Config):
        import anthropic
        self.anthropic = anthropic
        self.client = anthropic.Anthropic()
        self.model = cfg.claude_model
        self.name = f"claude/{cfg.claude_model}"

    def describe(self, frames_bgr: list[np.ndarray]) -> tuple[str | None, str | None]:
        content = []
        for f in frames_bgr:
            small = f if f.shape[1] <= 768 else cv2.resize(f, (768, int(f.shape[0] * 768 / f.shape[1])))
            ok, enc = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 80])
            content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                                        "data": base64.standard_b64encode(enc.tobytes()).decode()}})
        content.append({"type": "text", "text": DESCRIBE_PROMPT})
        try:
            resp = self.client.beta.messages.create(
                model=self.model, max_tokens=300,
                betas=["server-side-fallback-2026-07-01"], fallbacks="default",
                output_config={"effort": "low"},
                messages=[{"role": "user", "content": content}])
        except self.anthropic.RateLimitError:
            raise
        except self.anthropic.APIStatusError as e:
            log.warning("Claude API error %s: %s", e.status_code, e.message)
            return None, None
        if resp.stop_reason == "refusal":
            return None, None
        text = "".join(b.text for b in resp.content if b.type == "text")
        return _split_two(text)


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

class VisionPass:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.clip = None
        self.faces = None
        self.people = None
        self.describer = None
        if cfg.embed:
            try:
                self.clip = Clip(cfg)
            except Exception as e:
                log.warning("CLIP unavailable (%s); embeddings/scale/place/time skipped", e)
        if cfg.faces:
            self.faces = Faces(cfg.models_dir)
        if cfg.people:
            try:
                self.people = People(cfg.models_dir)
            except Exception as e:
                log.warning("YOLO unavailable (%s); people count skipped", e)
        if cfg.describe == "smolvlm":
            try:
                self.describer = SmolVLM(cfg)
            except Exception as e:
                log.warning("SmolVLM unavailable (%s); descriptions skipped", e)
        elif cfg.describe == "claude":
            try:
                self.describer = ClaudeDescriber(cfg)
            except Exception as e:
                log.warning("Claude API unavailable (%s); descriptions skipped", e)
        parts = [p for p in (self.clip and self.clip.name, self.faces and ("yunet" if self.faces.det else "haar"),
                             self.people and "yolov8n", self.describer and self.describer.name) if p]
        self.model_tag = "+".join(parts)

    def sample_frames(self, proxy: Path, start: int, end: int) -> list[np.ndarray]:
        n = end - start
        k = max(1, min(self.cfg.vision_frames_per_shot, 2))
        idxs = [start + n // 2] if k == 1 else [start + n // 4, start + (3 * n) // 4]
        frames = []
        for i in idxs:
            for _, f in iter_frames(proxy, i, i + 1):
                frames.append(f)
        return frames

    def run_shot(self, proxy: Path, shot: dict) -> tuple[dict, np.ndarray | None]:
        frames = self.sample_frames(proxy, shot["start_frame"], shot["end_frame"])
        out: dict = {}
        emb = None
        if not frames:
            return out, None
        if self.faces:
            fc, fs = max((self.faces.detect(f) for f in frames), key=lambda t: (t[0], t[1]))
            out["face_count"], out["face_size_max"] = fc, round(fs, 3)
        if self.people:
            out["people_count"] = max(self.people.count(f) for f in frames)
        elif self.faces:
            out["people_count"] = out["face_count"]
        if self.clip:
            emb = self.clip.embed(frames)
            sc = self.clip.zero_shot(emb, "scale")
            best = max(sc, key=sc.get)
            scale = SCALE_COLLAPSE[best]
            fs = out.get("face_size_max", 0.0)
            if fs >= 0.33:
                scale = "close-up"
            elif fs >= 0.14 and scale == "wide":
                scale = "medium"
            out["shot_scale"] = scale
            out["scale_scores_json"] = json.dumps({"raw": best, **sc})
            pl = self.clip.zero_shot(emb, "place")
            out["interior_exterior"] = max(pl, key=pl.get)
            tm = self.clip.zero_shot(emb, "time")
            night = tm["night"]
            if shot.get("brightness") is not None:
                # fold Layer 1 brightness in: very dark frames lean night, bright ones lean day
                night = 0.7 * night + 0.3 * (1.0 - min(1.0, shot["brightness"] / 0.5))
            out["day_night"] = "night" if night > 0.5 else "day"
        if self.describer:
            d, e = self.describer.describe(frames)
            out["description"], out["editorial"] = d, e
        if not out.get("editorial"):
            from .derive import editorial_reading
            out["editorial"] = editorial_reading({**shot, **out})
        return out, emb
