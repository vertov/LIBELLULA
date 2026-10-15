"""Score a config on one or more data folders with both scorers.
usage: eval_split.py CONFIG.json DIRS[:DIR...] [--only FILE] [--exclude FILE] [--perseq]"""
import os, sys, json, argparse
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from libstmd import data, model, metrics, trackmetrics

def load_names(f):
    return {l.split("\t")[0].strip() for l in open(f) if l.strip() and not l.startswith("#")}

def run(cfg, dirs, only=None, exclude=None, perseq=False):
    P = model.Params(**cfg)
    m = metrics.EvUAVMetrics(); tm = trackmetrics.TrackMetrics(); rows = []
    for d in dirs.split(":"):
        for s in data.load_dir(d):
            if only and s.name not in only: continue
            if exclude and s.name in exclude: continue
            o = model.run(s, P)
            m.update(s.t_ms, s.x, s.y, s.label, s.ident, o["pred"]); tm.update(s, o["tracks"])
            if perseq:
                mm = metrics.EvUAVMetrics(); mm.update(s.t_ms, s.x, s.y, s.label, s.ident, o["pred"])
                tt = trackmetrics.TrackMetrics(); tt.update(s, o["tracks"])
                rows.append((s.name, mm.result(), tt.result()))
    return m.result(), tm.result(), rows

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("config"); ap.add_argument("dirs")
    ap.add_argument("--only"); ap.add_argument("--exclude"); ap.add_argument("--perseq", action="store_true")
    a = ap.parse_args()
    r, t, rows = run(json.load(open(a.config)), a.dirs, load_names(a.only) if a.only else None,
                     load_names(a.exclude) if a.exclude else None, a.perseq)
    print(f"EVUAV IoU={r['IoU']:.3f} ACC={r['ACC']:.3f} Pd={r['Pd']:.3f} prec={r['precision']:.3f} fc/w={r['false_clusters_per_window']:.2f}")
    print(f"TRACK det={t['target_detected_rate']:.3f} ttfd_ms={t['time_to_first_detect_ms_median']:.0f} cov={t['window_coverage']:.3f} "
          f"false_tracks/min={t['false_tracks_per_min']:.2f} false_time={t['false_track_time_frac']:.3f} loc_med={t['loc_error_px_median']:.1f} loc_p90={t['loc_error_px_p90']:.1f} "
          f"(targets={t['n_targets']} tracks={t['n_tracks']} false={t['false_tracks']} min={t['duration_min']:.1f})")
    for name, r, t in rows:
        print(f"  {name:13} IoU={r['IoU']:.2f} Pd={r['Pd']:.2f} prec={r['precision']:.2f} fc/w={r['false_clusters_per_window']:5.2f} | det={t['target_detected_rate']:.2f} cov={t['window_coverage']:.2f} ft/min={t['false_tracks_per_min']:5.2f} ftime={t['false_track_time_frac']:.2f} loc={t['loc_error_px_median']:.1f}")
