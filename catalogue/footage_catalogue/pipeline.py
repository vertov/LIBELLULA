"""Orchestration: one file at a time, checkpoint after every layer, resumable."""
from __future__ import annotations

import json
import re
import sqlite3
import time
import traceback
from datetime import datetime
from pathlib import Path

from . import audio as audio_mod
from . import db, derive, export, render, visual
from . import shots as shots_mod
from .config import Config, scan_sources
from .edl import edl_to_boundaries, find_edl_for
from .log import Eta, Timer, fmt_dur, log
from .probe import ProbeInfo, frames_to_tc, probe, tc_to_frames
from .proxy import extract_audio, make_proxy


def _safe(stem: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", stem)[:60]


def _tag(file_id: int, info: ProbeInfo) -> str:
    return f"{file_id:05d}_{_safe(info.path.stem)}"


def _json_cols(shot: dict) -> dict:
    """Map a Layer 1 shot dict onto shots-table columns."""
    cols = dict(shot)
    cols["colors_json"] = db.j(cols.pop("colors", None))
    cols["frames_json"] = db.j(cols.pop("frames", None))
    cols["key_frame_path"] = cols.pop("key_frame", None)
    return cols


# ---------------------------------------------------------------------------
# Record assembly (single source for JSON / Markdown / HTML)
# ---------------------------------------------------------------------------

def _row(r: sqlite3.Row | None) -> dict:
    return dict(r) if r is not None else {}


def shot_dict(r: sqlite3.Row) -> dict:
    d = dict(r)
    d["colors"] = json.loads(d.pop("colors_json") or "[]")
    d["frames"] = json.loads(d.pop("frames_json") or "[]")
    d["scale_scores"] = json.loads(d.pop("scale_scores_json") or "null")
    d["key_frame"] = d.pop("key_frame_path")
    return d


def build_record(con: sqlite3.Connection, file_id: int) -> dict:
    f = _row(con.execute("SELECT * FROM files WHERE id=?", (file_id,)).fetchone())
    for k in ("silence_spans_json", "loudness_envelope_json", "duration_hist_json", "cut_timeline_json", "trajectories_json"):
        f[k[:-5]] = json.loads(f.pop(k) or "null")
    shots = [shot_dict(r) for r in db.shots_for(con, file_id)]
    segs = []
    for r in con.execute("SELECT * FROM audio_segments WHERE file_id=? ORDER BY idx", (file_id,)):
        d = dict(r); d["labels"] = json.loads(d.pop("labels_json") or "[]"); segs.append(d)
    tr = []
    for r in con.execute("SELECT * FROM transcripts WHERE file_id=? ORDER BY idx", (file_id,)):
        d = dict(r); d["words"] = json.loads(d.pop("words_json") or "[]"); tr.append(d)
    tags = {}
    for r in con.execute("""SELECT tl.target_type, tl.target_id, t.name, t.kind, tl.score, tl.source
                            FROM tag_links tl JOIN tags t ON t.id=tl.tag_id
                            WHERE (tl.target_type='file' AND tl.target_id=?)
                               OR (tl.target_type='shot' AND tl.target_id IN (SELECT id FROM shots WHERE file_id=?))""",
                         (file_id, file_id)):
        tags.setdefault(f"{r['target_type']}:{r['target_id']}", []).append(
            {"tag": r["name"], "kind": r["kind"], "score": r["score"], "source": r["source"]})
    for s in shots:
        s["tags"] = tags.get(f"shot:{s['id']}", [])
    audio = {k: f.get(k) for k in ("integrated_lufs", "loudness_range", "true_peak_dbtp", "sample_peak_dbfs",
                                   "silence_spans", "loudness_envelope", "language", "language_prob")}
    derived = {k: f.get(k) for k in ("shot_count", "mean_shot_sec", "median_shot_sec", "min_shot_sec", "max_shot_sec",
                                     "cuts_per_minute", "duration_hist", "cut_timeline", "trajectories")}
    return {"schema_version": 1, "generated_at": datetime.now().isoformat(timespec="seconds"),
            "file": f, "shots": shots, "audio": audio, "audio_segments": segs, "transcript": tr, "derived": derived}


# ---------------------------------------------------------------------------
# Layers
# ---------------------------------------------------------------------------

def layer1(con, cfg: Config, file_id: int, info: ProbeInfo, proxy_path: Path, tag: str) -> int:
    thumb_dir = cfg.thumbs_dir / tag
    edl = find_edl_for(info.path, cfg.edl_dir)
    n_frames = None
    if edl:
        log.info("  boundaries from EDL %s", edl.name)
        spans = edl_to_boundaries(edl, info.fps, info.start_timecode, info.nb_frames, cfg.edl_use_record)
        shots = []
        for i, (s, e, t) in enumerate(spans):
            shots.append((s, e, t if i else "start", spans[i + 1][2] if i + 1 < len(spans) else "end"))
        source = f"edl:{edl.name}"
        n_frames = spans[-1][1] if spans else info.nb_frames
    else:
        shots, source, n_frames = shots_mod.detect(proxy_path, cfg.detector, info.nb_frames, cfg.transnet_threshold,
                                                   cfg.psd_threshold, cfg.min_shot_frames)
    if info.nb_frames and n_frames and abs(n_frames - info.nb_frames) > 2:
        log.warning("  proxy has %d frames, source reports %d; timecodes derived from the proxy count", n_frames, info.nb_frames)
    log.info("  %d shots (%s)", len(shots), source)
    results, traj = visual.analyze(proxy_path, shots, info.fps, cfg, thumb_dir)
    base = tc_to_frames(info.start_timecode, info.fps) if info.start_timecode else 0
    rows = []
    for r in results:
        r["start_tc"] = frames_to_tc(base + r["start_frame"], info.fps)
        r["end_tc"] = frames_to_tc(base + r["end_frame"], info.fps)
        strip = render.filmstrip(r["frames"], thumb_dir, thumb_dir / f"shot_{r['idx']:04d}_strip.jpg")
        r["strip_path"] = strip.name if strip else None
        rows.append(_json_cols(r))
    with con:
        ids = db.replace_shots(con, file_id, rows)
        db.clear_tags(con, "shot", ids)
        for sid, r in zip(ids, results):
            if r.get("camera_motion"):
                db.link_tag(con, r["camera_motion"], "camera", "shot", sid, None, "flow")
            if r.get("hue_name"):
                db.link_tag(con, r["hue_name"], "colour", "shot", sid, None, "colour")
            db.link_tag(con, r["in_type"], "transition", "shot", sid, None, source.split(":")[0])
        db.update_file(con, file_id, l1_done=1, boundary_source=source, nb_frames=n_frames or info.nb_frames,
                       trajectories_json=db.j(traj), proxy_path=str(proxy_path), l3_done=0, l4_done=0)
    return len(rows)


def layer2(con, cfg: Config, file_id: int, info: ProbeInfo, wav: Path | None) -> None:
    if not info.has_audio or wav is None:
        log.info("  no audio track")
        with con:
            db.update_file(con, file_id, l2_done=1, has_audio=0, l4_done=0)
        return
    ls = audio_mod.loudness_and_silence(info.path, info.duration)
    windows = audio_mod.tag_windows(wav, cfg, cfg.tagger)
    segs = audio_mod.windows_to_segments(windows, info.duration)
    transcript, lang, lang_p = [], None, None
    if cfg.transcribe:
        try:
            transcript, lang, lang_p = audio_mod.transcribe(wav, cfg)
        except Exception as e:
            log.warning("  transcription failed: %s", e)
    if any(s["coarse"] == "sound" for s in segs):
        audio_mod.relabel_with_transcript(segs, transcript)
    shots = [shot_dict(r) for r in db.shots_for(con, file_id)]
    audio_mod.summarise_for_shots(shots, segs, transcript)
    with con:
        con.execute("DELETE FROM audio_segments WHERE file_id=?", (file_id,))
        con.execute("DELETE FROM transcripts WHERE file_id=?", (file_id,))
        seg_ids = []
        for s in segs:
            cur = con.execute("INSERT INTO audio_segments(file_id,idx,start_sec,end_sec,duration_sec,coarse,labels_json,rms_db,confidence)"
                              " VALUES (?,?,?,?,?,?,?,?,?)",
                              (file_id, s["idx"], s["start_sec"], s["end_sec"], s["duration_sec"], s["coarse"],
                               db.j(s["labels"]), s["rms_db"], s["confidence"]))
            seg_ids.append(cur.lastrowid)
        db.clear_tags(con, "audio_segment", seg_ids)
        for sid, s in zip(seg_ids, segs):
            db.link_tag(con, s["coarse"], "audio", "audio_segment", sid, s["confidence"], "panns" if cfg.tagger else "energy")
            for l in s["labels"][:3]:
                db.link_tag(con, l["label"], "audio", "audio_segment", sid, l["score"], "panns")
        for t in transcript:
            con.execute("INSERT INTO transcripts(file_id,idx,start_sec,end_sec,text,language,words_json,avg_logprob,no_speech_prob)"
                        " VALUES (?,?,?,?,?,?,?,?,?)",
                        (file_id, t["idx"], t["start_sec"], t["end_sec"], t["text"], t["language"], db.j(t["words"]),
                         t["avg_logprob"], t["no_speech_prob"]))
        for s in shots:
            db.update_shot(con, s["id"], audio_class=s["audio_class"], speech_frac=s["speech_frac"], music_frac=s["music_frac"],
                           silence_frac=s["silence_frac"], audio_bridge_in=s["audio_bridge_in"], audio_bridge_out=s["audio_bridge_out"],
                           speech_bridge_in=s["speech_bridge_in"], speech_bridge_out=s["speech_bridge_out"],
                           transcript_text=s["transcript_text"])
            db.clear_tags(con, "shot", [s["id"]], source="audio")
            if s["audio_class"] not in (None, "none"):
                db.link_tag(con, s["audio_class"], "audio", "shot", s["id"], None, "audio")
        db.update_file(con, file_id, l2_done=1, has_audio=1, integrated_lufs=ls["integrated_lufs"], loudness_range=ls["loudness_range"],
                       true_peak_dbtp=ls["true_peak_dbtp"], sample_peak_dbfs=ls["sample_peak_dbfs"],
                       silence_spans_json=db.j(ls["silence_spans"]), loudness_envelope_json=db.j(ls["envelope_1hz"]),
                       language=lang, language_prob=lang_p, l4_done=0)
    log.info("  audio: %d segments, %d transcript segments, %s LUFS, lang %s",
             len(segs), len(transcript), ls["integrated_lufs"], lang)


def layer3(con, cfg: Config, file_id: int, proxy_path: Path, vp) -> int:
    """Run the model pass over this file's pending shots.  Commits every few shots; resumable."""
    rows = con.execute("SELECT * FROM shots WHERE file_id=? AND vision_done=0 ORDER BY idx", (file_id,)).fetchall()
    done = 0
    pending = []
    for r in rows:
        s = shot_dict(r)
        if s["duration_sec"] < cfg.vision_min_shot_sec:
            pending.append((s["id"], {"vision_done": 1, "vision_model": "skipped:short"}, None))
        else:
            try:
                out, emb = vp.run_shot(proxy_path, s)
            except Exception as e:
                log.warning("  vision failed on shot %d: %s", s["idx"], e)
                out, emb = {"vision_model": f"error:{type(e).__name__}"}, None
            out["vision_done"] = 1
            out.setdefault("vision_model", vp.model_tag)
            pending.append((s["id"], out, emb))
        done += 1
        if len(pending) >= 8:
            _commit_vision(con, cfg, pending, vp); pending = []
    if pending:
        _commit_vision(con, cfg, pending, vp)
    left = con.execute("SELECT COUNT(*) FROM shots WHERE file_id=? AND vision_done=0", (file_id,)).fetchone()[0]
    if left == 0:
        with con:
            db.update_file(con, file_id, l3_done=1, l4_done=0)
    return done


def _commit_vision(con, cfg: Config, pending, vp) -> None:
    with con:
        for sid, out, emb in pending:
            db.update_shot(con, sid, **out)
            db.clear_tags(con, "shot", [sid], source="clip")
            db.clear_tags(con, "shot", [sid], source="faces")
            for key, kind in (("shot_scale", "scale"), ("interior_exterior", "place"), ("day_night", "light")):
                if out.get(key):
                    db.link_tag(con, out[key], kind, "shot", sid, None, "clip")
            if out.get("face_count"):
                db.link_tag(con, "faces", "content", "shot", sid, float(out["face_count"]), "faces")
            if emb is not None and vp.clip is not None:
                db.put_embedding(con, sid, vp.clip.name, emb)


def layer4(con, cfg: Config, file_id: int, tag: str) -> dict:
    rec = build_record(con, file_id)
    f = rec["file"]
    st = derive.summarise(f, rec["shots"], rec["audio_segments"], rec["transcript"])
    thumb_dir = cfg.thumbs_dir / tag
    sheet = thumb_dir / "contact_sheet.jpg"
    subtitle = (f"{f['width']}x{f['height']} {f['fps']:.3f} fps  {fmt_dur(f['duration_sec'])}  {st['shot_count']} shots  "
                f"mean {st['mean_shot_sec'] or 0:.1f}s  median {st['median_shot_sec'] or 0:.1f}s  {f.get('boundary_source')}")
    render.contact_sheet(rec["shots"], thumb_dir, sheet, f["filename"], subtitle)
    json_path = cfg.json_dir / f"{tag}.json"
    md_path = cfg.md_dir / f"{tag}.md"
    with con:
        db.update_file(con, file_id, l4_done=1, shot_count=st["shot_count"], mean_shot_sec=st["mean_shot_sec"],
                       median_shot_sec=st["median_shot_sec"], min_shot_sec=st["min_shot_sec"], max_shot_sec=st["max_shot_sec"],
                       cuts_per_minute=st["cuts_per_minute"], duration_hist_json=db.j(st["duration_hist"]),
                       cut_timeline_json=db.j(st["cut_timeline"]), trajectories_json=db.j({**(f.get("trajectories") or {}), **st["trajectories"]}),
                       summary=st["summary"], contact_sheet_path=str(sheet), json_path=str(json_path), md_path=str(md_path))
    rec = build_record(con, file_id)
    export.write_json(rec, json_path)
    export.write_markdown(rec, md_path, f"../thumbs/{tag}/contact_sheet.jpg")
    return rec


# ---------------------------------------------------------------------------
# Per-file driver
# ---------------------------------------------------------------------------

def register_file(con, cfg: Config, src: Path) -> tuple[int, ProbeInfo]:
    info = probe(src)
    try:
        rel = str(src.resolve().relative_to(cfg.source_root.resolve()))
    except ValueError:
        rel = src.name
    row = {"path": str(src.resolve()), "rel_path": rel, "filename": src.name, "size_bytes": info.size_bytes,
           "mtime": src.stat().st_mtime, "duration_sec": info.duration, "fps": info.fps, "fps_num": info.fps_num,
           "fps_den": info.fps_den, "width": info.width, "height": info.height, "codec": info.codec,
           "start_timecode": info.start_timecode, "vfr": int(info.vfr), "has_audio": int(info.has_audio),
           "audio_channels": info.audio_channels, "audio_layout": info.audio_layout,
           "audio_sample_rate": info.audio_sample_rate, "audio_codec": info.audio_codec}
    existing = con.execute("SELECT id, nb_frames, size_bytes, mtime FROM files WHERE path=?", (row["path"],)).fetchone()
    if existing is None or existing["nb_frames"] is None:
        row["nb_frames"] = info.nb_frames
    with con:
        fid = db.upsert_file(con, row)
        if existing is not None and (existing["size_bytes"] != info.size_bytes or abs((existing["mtime"] or 0) - row["mtime"]) > 1):
            log.info("  source changed since last run; redoing all layers")
            db.update_file(con, fid, l1_done=0, l2_done=0, l3_done=0, l4_done=0)
    return fid, info


def process_file(con, cfg: Config, src: Path, vp=None) -> dict[str, float]:
    t = Timer()
    fid, info = register_file(con, cfg, src)
    row = con.execute("SELECT * FROM files WHERE id=?", (fid,)).fetchone()
    tag = _tag(fid, info)
    need_l1 = cfg.force or not row["l1_done"]
    need_l2 = cfg.audio and (cfg.force or not row["l2_done"])
    need_l3 = cfg.vision and vp is not None and (cfg.force or not row["l3_done"])
    proxy_path = cfg.proxies_dir / f"{tag}.mp4"
    wav_path = cfg.proxies_dir / f"{tag}.wav"
    if need_l1 or need_l3:
        make_proxy(info, proxy_path, cfg.proxy_height, hwaccel=cfg.hwaccel)
    if need_l2 and info.has_audio:
        extract_audio(info, wav_path)
    t.lap("proxy")
    if need_l1:
        layer1(con, cfg, fid, info, proxy_path, tag)
    t.lap("l1")
    if need_l2:
        layer2(con, cfg, fid, info, wav_path if info.has_audio else None)
    t.lap("l2")
    if need_l3:
        layer3(con, cfg, fid, proxy_path, vp)
    t.lap("l3")
    row = con.execute("SELECT l4_done FROM files WHERE id=?", (fid,)).fetchone()
    if cfg.force or not row["l4_done"] or need_l1 or need_l2 or need_l3:
        layer4(con, cfg, fid, tag)
    t.lap("l4")
    if not cfg.keep_proxies:
        for p in (proxy_path, wav_path):
            if p.exists():
                p.unlink()
    with con:
        db.update_file(con, fid, runtime_proxy=t.marks.get("proxy"), runtime_l1=t.marks.get("l1") if need_l1 else None,
                       runtime_l2=t.marks.get("l2") if need_l2 else None, runtime_l3=t.marks.get("l3") if need_l3 else None,
                       runtime_l4=t.marks.get("l4"), error=None)
    return t.marks


def run(cfg: Config, sources: list[Path] | None = None) -> None:
    cfg.ensure_dirs()
    con = db.connect(cfg.db_path)
    files = sources if sources is not None else scan_sources(cfg.source_root)
    if not files:
        log.error("no video files under %s", cfg.source_root)
        return
    log.info("%d video files under %s", len(files), cfg.source_root)
    # total footage for the ETA (ffprobe is cheap)
    durations = {}
    for p in files:
        try:
            durations[p] = probe(p).duration
        except Exception as e:
            log.warning("probe failed for %s: %s", p, e)
    total = sum(durations.values())
    log.info("total footage %s", fmt_dur(total))
    eta = Eta(total, cfg.logs_dir / "timings.csv")
    with con:
        cur = con.execute("INSERT INTO runs(started_at, args) VALUES (?,?)", (datetime.now().isoformat(timespec="seconds"), cfg.to_json()))
        run_id = cur.lastrowid
    vp = None
    if cfg.vision:
        from .vision import VisionPass
        vp = VisionPass(cfg)
    n_done = 0
    touched = []
    for i, src in enumerate(files):
        if src not in durations:
            continue
        if cfg.limit is not None and n_done >= cfg.limit:
            break
        log.info("[%d/%d] %s (%s)", i + 1, len(files), src.name, fmt_dur(durations[src]))
        try:
            marks = process_file(con, cfg, src, vp)
        except KeyboardInterrupt:
            log.warning("interrupted; progress up to the last completed layer is saved")
            break
        except Exception as e:
            log.error("  FAILED %s: %s", src.name, e)
            log.debug(traceback.format_exc())
            try:
                with con:
                    con.execute("UPDATE files SET error=? WHERE path=?", (f"{type(e).__name__}: {e}"[:500], str(src.resolve())))
            except Exception:
                pass
            continue
        n_done += 1
        touched.append(src)
        eta.record(src.name, durations[src], marks)
        total_s = sum(marks.values())
        log.info("  done in %s (proxy %.0fs, L1 %.0fs, L2 %.0fs, L3 %.0fs, L4 %.0fs) = %.2fx realtime",
                 fmt_dur(total_s), marks.get("proxy", 0), marks.get("l1", 0), marks.get("l2", 0), marks.get("l3", 0),
                 marks.get("l4", 0), total_s / max(1e-6, durations[src]))
        if n_done >= cfg.max_files_for_eta or n_done == len(files):
            factor, remaining = eta.estimate()
            log.info("  speed %.2fx realtime; estimated remaining %s for %s of footage",
                     factor, fmt_dur(remaining), fmt_dur(max(0.0, total - eta.done_footage)))
        if cfg.html:
            from .html import build_site
            build_site(con, cfg)
    with con:
        con.execute("UPDATE runs SET finished_at=?, files_done=? WHERE id=?",
                    (datetime.now().isoformat(timespec="seconds"), n_done, run_id))
    eta.close()
    log.info("run complete: %d files processed", n_done)


def run_vision(cfg: Config, sources: list[Path] | None = None) -> None:
    """Layer 3 over existing Layer 1 output (separately runnable, resumable)."""
    cfg.ensure_dirs()
    con = db.connect(cfg.db_path)
    from .vision import VisionPass
    vp = VisionPass(cfg)
    q = "SELECT * FROM files WHERE l1_done=1" + ("" if cfg.force else " AND l3_done=0") + " ORDER BY rel_path"
    rows = con.execute(q).fetchall()
    if sources:
        want = {str(p.resolve()) for p in sources}
        rows = [r for r in rows if r["path"] in want]
    log.info("vision pass over %d files", len(rows))
    t0 = time.perf_counter()
    done_files = 0
    for r in rows:
        if cfg.limit is not None and done_files >= cfg.limit:
            break
        src = Path(r["path"])
        if not src.exists():
            log.warning("source missing: %s", src)
            continue
        info = probe(src)
        tag = _tag(r["id"], info)
        proxy_path = cfg.proxies_dir / f"{tag}.mp4"
        if not proxy_path.exists():
            make_proxy(info, proxy_path, cfg.proxy_height, hwaccel=cfg.hwaccel)
        if cfg.force:
            with con:
                con.execute("UPDATE shots SET vision_done=0 WHERE file_id=?", (r["id"],))
        t = time.perf_counter()
        n = layer3(con, cfg, r["id"], proxy_path, vp)
        layer4(con, cfg, r["id"], tag)
        with con:
            db.update_file(con, r["id"], runtime_l3=time.perf_counter() - t)
        done_files += 1
        log.info("[%d/%d] %s: %d shots in %.0fs", done_files, len(rows), src.name, n, time.perf_counter() - t)
        if cfg.html:
            from .html import build_site
            build_site(con, cfg)
    log.info("vision pass complete in %s", fmt_dur(time.perf_counter() - t0))
