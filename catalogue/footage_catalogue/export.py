"""Per-file JSON and Markdown records (portable, independent of the database)."""
from __future__ import annotations

import json
from pathlib import Path

from .probe import sec_to_hms


def write_json(record: dict, dst: Path) -> Path:
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_suffix(".tmp")
    tmp.write_text(json.dumps(record, indent=1, ensure_ascii=False), encoding="utf-8")
    tmp.replace(dst)
    return dst


def write_markdown(record: dict, dst: Path, contact_sheet_rel: str | None) -> Path:
    f = record["file"]
    shots = record["shots"]
    lines = [f"# {f['filename']}", ""]
    lines.append(f"`{f['path']}`  ")
    lines.append(f"{f['width']}x{f['height']} @ {f['fps']:.3f} fps ({f['fps_num']}/{f['fps_den']}), "
                 f"{sec_to_hms(f['duration_sec'])}, {f['nb_frames']} frames, codec {f['codec']}, "
                 f"audio: {f['audio_layout'] or 'none'}"
                 + (f", start TC {f['start_timecode']}" if f.get("start_timecode") else "") + "  ")
    lines.append(f"Boundaries: {f.get('boundary_source')}")
    lines.append("")
    if f.get("summary"):
        lines += ["## Summary", "", f["summary"], ""]
    d = record.get("derived") or {}
    if d:
        lines += ["## Structure", ""]
        lines.append(f"- shots: {d.get('shot_count')}  mean {d.get('mean_shot_sec')} s  median {d.get('median_shot_sec')} s  "
                     f"min {d.get('min_shot_sec')} s  max {d.get('max_shot_sec')} s  cuts/min {d.get('cuts_per_minute')}")
        h = d.get("duration_hist") or {}
        if h:
            lines.append("- duration histogram: " + ", ".join(f"{l}: {c}" for l, c in zip(h["labels"], h["counts"])))
        lines.append("")
    a = record.get("audio") or {}
    if a:
        lines += ["## Audio", ""]
        lines.append(f"- integrated {a.get('integrated_lufs')} LUFS, LRA {a.get('loudness_range')} LU, "
                     f"true peak {a.get('true_peak_dbtp')} dBTP, language {a.get('language')}")
        if a.get("silence_spans"):
            lines.append("- silence spans: " + ", ".join(f"{s[0]:.1f}-{s[1]:.1f}" for s in a["silence_spans"][:20]))
        segs = record.get("audio_segments") or []
        if segs:
            lines.append("")
            lines.append("| start | end | class | labels |")
            lines.append("|---|---|---|---|")
            for s in segs:
                labs = ", ".join(l["label"] for l in s.get("labels", [])[:3])
                lines.append(f"| {s['start_sec']:.1f} | {s['end_sec']:.1f} | {s['coarse']} | {labs} |")
        lines.append("")
    if contact_sheet_rel:
        lines += ["## Contact sheet", "", f"![contact sheet]({contact_sheet_rel})", ""]
    lines += ["## Shots", ""]
    lines.append("| # | in TC | out TC | dur s | in | cam | scale | bright | sat | hue | motion | audio | description |")
    lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for s in shots:
        desc = (s.get("description") or "")[:80]
        lines.append(f"| {s['idx'] + 1} | {s.get('start_tc')} | {s.get('end_tc')} | {s['duration_sec']:.2f} | {s['in_type']} | "
                     f"{s.get('camera_motion') or ''} | {s.get('shot_scale') or ''} | {s.get('brightness')} | {s.get('saturation')} | "
                     f"{s.get('hue_name') or ''} | {s.get('motion_total')} | {s.get('audio_class') or ''} | {desc} |")
    tr = record.get("transcript") or []
    if tr:
        lines += ["", "## Transcript", ""]
        for t in tr:
            lines.append(f"- **{sec_to_hms(t['start_sec'])[:-4]}** {t['text']}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return dst
