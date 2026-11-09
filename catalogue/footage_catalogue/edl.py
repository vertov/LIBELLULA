"""CMX3600 EDL parsing (DaVinci Resolve export, including Scene Cut Detection EDLs).

An EDL supplied for a file overrides shot detection.  Each event's source
in/out (or record in/out with ``use_record``) becomes a shot; the event's
transition code (C / D / W / K) becomes the shot's in_type.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from .probe import tc_to_frames

EVENT_RE = re.compile(
    r"^\s*(\d{3,6})\s+(\S+)\s+(\S+)\s+(C|D|W\d*|K\s*B?|K)\s*(\d+)?\s+"
    r"(\d{2}[:;.]\d{2}[:;.]\d{2}[:;.]\d{2})\s+(\d{2}[:;.]\d{2}[:;.]\d{2}[:;.]\d{2})\s+"
    r"(\d{2}[:;.]\d{2}[:;.]\d{2}[:;.]\d{2})\s+(\d{2}[:;.]\d{2}[:;.]\d{2}[:;.]\d{2})\s*$"
)


@dataclass
class EdlEvent:
    num: int
    reel: str
    track: str
    transition: str       # C, D, W, K
    duration: int | None  # transition length in frames (D/W)
    src_in: str
    src_out: str
    rec_in: str
    rec_out: str


def parse_edl(path: Path) -> tuple[list[EdlEvent], dict]:
    events: list[EdlEvent] = []
    meta: dict = {"title": None, "fcm": None}
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if line.upper().startswith("TITLE:"):
            meta["title"] = line.split(":", 1)[1].strip()
            continue
        if line.upper().startswith("FCM:"):
            meta["fcm"] = line.split(":", 1)[1].strip()
            continue
        m = EVENT_RE.match(line)
        if not m:
            continue
        tr = m.group(4).strip()
        events.append(EdlEvent(
            num=int(m.group(1)), reel=m.group(2), track=m.group(3),
            transition=tr[0], duration=int(m.group(5)) if m.group(5) else None,
            src_in=m.group(6), src_out=m.group(7), rec_in=m.group(8), rec_out=m.group(9)))
    return events, meta


_TRANS_NAME = {"C": "cut", "D": "dissolve", "W": "wipe", "K": "key"}


def edl_to_boundaries(path: Path, fps: float, file_start_tc: str | None, nb_frames: int | None,
                      use_record: bool = False) -> list[tuple[int, int, str]]:
    """Return [(start_frame, end_frame_exclusive, in_type), ...] relative to the file start.

    Source TCs are interpreted relative to the file's own start timecode (or 00:00:00:00
    when the file has none).  With ``use_record`` the record TCs are used, relative to
    the first event's record-in (Resolve timelines usually start at 01:00:00:00).
    """
    events, _ = parse_edl(path)
    events = [e for e in events if e.track.upper().startswith("V") or e.track.upper() in ("B", "AA/V", "A/V")]
    if not events:
        raise ValueError(f"no video events in EDL {path}")
    base = 0
    if use_record:
        base = tc_to_frames(events[0].rec_in, fps)
        spans = [(tc_to_frames(e.rec_in, fps) - base, tc_to_frames(e.rec_out, fps) - base, e) for e in events]
    else:
        base = tc_to_frames(file_start_tc, fps) if file_start_tc else 0
        spans = [(tc_to_frames(e.src_in, fps) - base, tc_to_frames(e.src_out, fps) - base, e) for e in events]
    spans.sort(key=lambda t: t[0])
    out: list[tuple[int, int, str]] = []
    for s, e, ev in spans:
        s = max(0, s)
        if nb_frames:
            e = min(e, nb_frames)
        if e <= s:
            continue
        out.append((s, e, "edl_" + _TRANS_NAME.get(ev.transition, ev.transition.lower())))
    # Fill gaps so the whole file is covered (gaps become their own shots).
    filled: list[tuple[int, int, str]] = []
    cursor = 0
    for s, e, t in out:
        if s > cursor:
            filled.append((cursor, s, "edl_gap"))
        filled.append((max(s, cursor), e, t))
        cursor = max(cursor, e)
    if nb_frames and cursor < nb_frames:
        filled.append((cursor, nb_frames, "edl_gap"))
    return filled


def find_edl_for(video: Path, edl_dir: Path | None) -> Path | None:
    cands = [video.with_suffix(".edl"), video.with_suffix(".EDL")]
    if edl_dir:
        cands += [edl_dir / (video.stem + ".edl"), edl_dir / (video.stem + ".EDL")]
    for c in cands:
        if c.exists():
            return c
    return None
