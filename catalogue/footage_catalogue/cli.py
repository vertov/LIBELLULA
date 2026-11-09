"""Command-line entry point: ``fcat run | vision | html | export | status``."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .config import Config, scan_sources
from .log import fmt_dur, log, setup_logging

DEFAULT_SOURCE = "/Volumes/Super/CollectedFootage"
DEFAULT_OUT = "/Volumes/G-DRIVE PRO SSD/FootageCatalogue"


def _common(p: argparse.ArgumentParser) -> None:
    p.add_argument("--source", default=DEFAULT_SOURCE, help="source root (never written to)")
    p.add_argument("--out", default=DEFAULT_OUT, help="output root (database, proxies, thumbs, html, logs)")
    p.add_argument("-v", "--verbose", action="store_true")
    p.add_argument("--force", action="store_true", help="redo layers already marked done")
    p.add_argument("--limit", type=int, help="process at most N files this run")
    p.add_argument("--no-html", action="store_true", help="do not regenerate the HTML index after each file")


def _layer_flags(p: argparse.ArgumentParser) -> None:
    g = p.add_argument_group("passes")
    g.add_argument("--no-audio", action="store_true", help="skip Layer 2 entirely")
    g.add_argument("--no-tagger", action="store_true", help="skip PANNs sound tagging (energy-only segmentation)")
    g.add_argument("--no-transcribe", action="store_true", help="skip Whisper")
    g.add_argument("--no-flow", action="store_true", help="skip optical flow (fastest Layer 1)")
    g.add_argument("--vision", action="store_true", help="run Layer 3 during `run` (otherwise use `fcat vision` later)")
    g.add_argument("--no-embed", action="store_true", help="skip CLIP (embedding, scale, place, day/night)")
    g.add_argument("--no-faces", action="store_true")
    g.add_argument("--people", action="store_true", help="count people with YOLOv8n (pip install ultralytics)")
    g.add_argument("--describe", choices=["off", "smolvlm", "claude"], default="off",
                   help="per-shot description + editorial line: local SmolVLM or the Claude API")
    d = p.add_argument_group("detection")
    d.add_argument("--detector", choices=["auto", "transnetv2", "pyscenedetect"], default="auto")
    d.add_argument("--transnet-threshold", type=float, default=0.5)
    d.add_argument("--psd-threshold", type=float, default=27.0)
    d.add_argument("--min-shot-frames", type=int, default=2)
    d.add_argument("--edl-dir", help="directory holding <stem>.edl files that override detection")
    d.add_argument("--edl-use-record", action="store_true", help="use EDL record TCs (relative to first event) instead of source TCs")
    r = p.add_argument_group("resources")
    r.add_argument("--proxy-height", type=int, default=480)
    r.add_argument("--stride", type=int, default=2, help="analyse every Nth proxy frame for colour/flow")
    r.add_argument("--hwaccel", default="auto", help="ffmpeg hwaccel for proxy decode: auto | none | videotoolbox")
    r.add_argument("--whisper-model", default="small", help="tiny | base | small | medium | large-v3 | distil-large-v3")
    r.add_argument("--clip-model", default="ViT-B-32")
    r.add_argument("--clip-pretrained", default="laion2b_s34b_b79k")
    r.add_argument("--vlm-model", default="HuggingFaceTB/SmolVLM-500M-Instruct")
    r.add_argument("--claude-model", default="claude-opus-5-5")
    r.add_argument("--vision-frames", type=int, default=2, choices=[1, 2], help="frames sampled per shot for the model pass")
    r.add_argument("--vision-min-sec", type=float, default=0.5, help="skip the model pass on shots shorter than this")
    r.add_argument("--delete-proxies", action="store_true", help="delete proxies/wavs after each file (HTML loses in-browser playback)")


def make_config(a: argparse.Namespace) -> Config:
    cfg = Config(source_root=Path(a.source).expanduser(), out_root=Path(a.out).expanduser())
    cfg.force = a.force
    cfg.limit = a.limit
    cfg.html = not a.no_html
    if hasattr(a, "no_audio"):
        cfg.audio = not a.no_audio
        cfg.tagger = not a.no_tagger
        cfg.transcribe = not a.no_transcribe
        cfg.flow = not a.no_flow
        cfg.vision = a.vision
        cfg.embed = not a.no_embed
        cfg.faces = not a.no_faces
        cfg.people = a.people
        cfg.describe = a.describe
        cfg.detector = a.detector
        cfg.transnet_threshold = a.transnet_threshold
        cfg.psd_threshold = a.psd_threshold
        cfg.min_shot_frames = a.min_shot_frames
        cfg.edl_dir = Path(a.edl_dir).expanduser() if a.edl_dir else None
        cfg.edl_use_record = a.edl_use_record
        cfg.proxy_height = a.proxy_height
        cfg.analysis_stride = a.stride
        cfg.hwaccel = a.hwaccel
        cfg.whisper_model = a.whisper_model
        cfg.clip_model = a.clip_model
        cfg.clip_pretrained = a.clip_pretrained
        cfg.vlm_model = a.vlm_model
        cfg.claude_model = a.claude_model
        cfg.vision_frames_per_shot = a.vision_frames
        cfg.vision_min_shot_sec = a.vision_min_sec
        cfg.keep_proxies = not a.delete_proxies
    return cfg


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="fcat", description="Shot-by-shot structural catalogue of a footage archive.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_run = sub.add_parser("run", help="process files: proxy, Layer 1, Layer 2, [Layer 3], Layer 4, exports, HTML")
    p_run.add_argument("files", nargs="*", help="specific video files (default: everything under --source)")
    _common(p_run); _layer_flags(p_run)

    p_vis = sub.add_parser("vision", help="Layer 3 model pass over files already analysed (resumable)")
    p_vis.add_argument("files", nargs="*")
    _common(p_vis); _layer_flags(p_vis)

    p_html = sub.add_parser("html", help="regenerate the static HTML index from the database")
    _common(p_html)

    p_exp = sub.add_parser("export", help="rewrite per-file JSON/Markdown and contact sheets from the database")
    _common(p_exp)

    p_st = sub.add_parser("status", help="show progress")
    _common(p_st)

    p_scan = sub.add_parser("scan", help="list the video files that would be processed")
    _common(p_scan)

    a = ap.parse_args(argv)
    cfg = make_config(a)
    if a.cmd == "scan":
        files = scan_sources(cfg.source_root)
        for f in files:
            print(f)
        print(f"{len(files)} files", file=sys.stderr)
        return 0
    cfg.ensure_dirs()
    logp = setup_logging(cfg.logs_dir, a.verbose)
    log.debug("config:\n%s", cfg.to_json())
    log.info("log: %s", logp)
    from . import db, pipeline
    if a.cmd == "run":
        if a.vision:
            cfg.vision = True
        files = [Path(f).expanduser() for f in a.files] or None
        pipeline.run(cfg, files)
    elif a.cmd == "vision":
        cfg.vision = True
        files = [Path(f).expanduser() for f in a.files] or None
        pipeline.run_vision(cfg, files)
    elif a.cmd == "html":
        from .html import build_site
        con = db.connect(cfg.db_path)
        print(build_site(con, cfg))
    elif a.cmd == "export":
        con = db.connect(cfg.db_path)
        for r in con.execute("SELECT id, path, proxy_path FROM files WHERE l1_done=1"):
            from .probe import probe
            tag = Path(r["proxy_path"]).stem if r["proxy_path"] else pipeline._tag(r["id"], probe(Path(r["path"])))
            pipeline.layer4(con, cfg, r["id"], tag)
            log.info("exported %s", r["path"])
        from .html import build_site
        build_site(con, cfg)
    elif a.cmd == "status":
        con = db.connect(cfg.db_path)
        rows = con.execute("SELECT * FROM files ORDER BY rel_path").fetchall()
        tot = con.execute("SELECT COUNT(*) n, SUM(duration_sec) d FROM files").fetchone()
        done = con.execute("SELECT COUNT(*) FROM files WHERE l1_done=1 AND l4_done=1").fetchone()[0]
        shots = con.execute("SELECT COUNT(*), SUM(vision_done) FROM shots").fetchone()
        print(f"{tot['n']} files registered, {done} complete through Layer 4, {fmt_dur(tot['d'] or 0)} of footage")
        print(f"{shots[0] or 0} shots, {shots[1] or 0} through the vision pass")
        for r in rows:
            flags = "".join(str(i + 1) if r[f"l{i + 1}_done"] else "." for i in range(4))
            err = f"  ERROR {r['error']}" if r["error"] else ""
            print(f"  [{flags}] {r['rel_path']}  {fmt_dur(r['duration_sec'] or 0)}  shots={r['shot_count']}{err}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
