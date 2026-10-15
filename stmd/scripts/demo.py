"""Run the detector on one event recording and write the result as a video.

usage:
  demo.py EVENTS [--config configs/selected.json] [--out results/demo]
          [--frame-ms 20] [--fps 25] [--width 346 --height 260] [--max-s 8]

EVENTS is either an EV-UAV .npz (fields x, y, t[ms], p, label) or any .npz /
.npy with arrays x, y, t_us (or t_ms), p. Ground-truth labels are drawn when
present; the detector never sees them.

Writes:
  OUT.npz   per-event arrays: pred (detector label), baf, cand, plus the
            confirmed-track log (t_us, uid, x, y, vx, vy)
  OUT.mp4   event frames (OFF dark, ON light) with detector labels in red,
            ground truth in green when available, confirmed tracks as circles
  OUT.gif   the first --max-s seconds, for READMEs
Prints the EV-UAV scores when ground truth is present.
"""
import os, sys, json, argparse
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import numpy as np


def load_events(path):
    d = np.load(path, allow_pickle=False)
    if isinstance(d, np.ndarray):                       # .npy structured array
        ev = d; t_us = np.round(ev["t"] * 1000).astype(np.int64) if ev.dtype.fields and "t" in ev.dtype.fields else ev["t_us"]
        return ev["x"].astype(np.int32), ev["y"].astype(np.int32), t_us, ev["p"].astype(np.int8), None, None
    if "ev" in d.files:                                 # EV-UAV
        ev = d["ev"]
        lab = ev["label"].astype(np.int8) if "label" in ev.dtype.fields else None
        ident = ev["name"].astype(np.int16) if "name" in ev.dtype.fields else None
        return (ev["x"].astype(np.int32), ev["y"].astype(np.int32),
                np.round(ev["t"] * 1000.0).astype(np.int64), ev["p"].astype(np.int8), lab, ident)
    x, y, p = d["x"].astype(np.int32), d["y"].astype(np.int32), d["p"].astype(np.int8)
    t_us = d["t_us"].astype(np.int64) if "t_us" in d.files else np.round(d["t_ms"] * 1000.0).astype(np.int64)
    lab = d["label"].astype(np.int8) if "label" in d.files else None
    return x, y, t_us, p, lab, None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("events"); ap.add_argument("--config", default=os.path.join(ROOT, "configs", "selected.json"))
    ap.add_argument("--out", default=os.path.join(ROOT, "results", "demo"))
    ap.add_argument("--frame-ms", type=float, default=20.0); ap.add_argument("--fps", type=int, default=25)
    ap.add_argument("--width", type=int, default=346); ap.add_argument("--height", type=int, default=260)
    ap.add_argument("--max-s", type=float, default=8.0, help="seconds of video to write (the .npz covers the whole recording)")
    ap.add_argument("--persist-ms", type=float, default=120.0, help="events stay visible this long, fading")
    ap.add_argument("--no-video", action="store_true")
    a = ap.parse_args()

    from libstmd import model
    x, y, t_us, p, label, ident = load_events(a.events)
    order = np.argsort(t_us, kind="stable"); x, y, t_us, p = x[order], y[order], t_us[order], p[order]
    if label is not None: label = label[order]
    if ident is not None: ident = ident[order]
    cfg = json.load(open(a.config)); P = model.Params(**cfg)
    o = model.run((x, y, t_us, p), P)
    pred = o["pred"]; trk = o["tracks"]
    os.makedirs(os.path.dirname(os.path.abspath(a.out)) or ".", exist_ok=True)
    np.savez_compressed(a.out + ".npz", pred=pred, baf=o["baf"], cand=o["cand"],
                        trk_t_us=trk["t_us"], trk_uid=trk["uid"], trk_x=trk["x"], trk_y=trk["y"], trk_vx=trk["vx"], trk_vy=trk["vy"])
    dur = (t_us[-1] - t_us[0]) / 1e6
    print(f"{os.path.basename(a.events)}: {len(x)} events over {dur:.1f} s; labelled {int(pred.sum())} as target; "
          f"{len(np.unique(trk['uid']))} confirmed tracks; wrote {a.out}.npz")
    if label is not None:
        from libstmd import metrics
        if ident is None: ident = (label > 0).astype(np.int16)
        m = metrics.EvUAVMetrics(); m.update(t_us // 1000, x, y, label, ident, pred); r = m.result()
        print(f"EV-UAV scorer: IoU {r['IoU']:.3f}  recall {r['ACC']:.3f}  precision {r['precision']:.3f}  Pd {r['Pd']:.3f}")
    if a.no_video: return

    import imageio.v2 as imageio
    W, H = a.width, a.height
    t0 = t_us[0]; T = min(dur, a.max_s) if a.max_s > 0 else dur
    nfr = int(np.ceil(T * 1000.0 / a.frame_ms))
    fidx = ((t_us - t0) / 1000.0 / a.frame_ms).astype(np.int64)
    tfidx = ((trk["t_us"] - t0) / 1000.0 / a.frame_ms).astype(np.int64)
    frames = []
    yy, xx = np.mgrid[-11:12, -11:12]; ring = (xx * xx + yy * yy >= 100) & (xx * xx + yy * yy <= 121)
    def blob(img, xs, ys, col):
        for dx in (0, 1):
            for dy in (0, 1):
                img[np.clip(ys + dy, 0, H - 1), np.clip(xs + dx, 0, W - 1)] = col
    npersist = max(1, int(round(a.persist_ms / a.frame_ms)))
    for f in range(nfr):
        img = np.full((H, W, 3), 24, np.uint8)
        for back in range(npersist - 1, -1, -1):          # oldest first, newest drawn last
            sel = np.nonzero(fidx == f - back)[0]
            if not sel.size: continue
            fade = 1.0 - 0.8 * back / npersist
            xs, ys = np.clip(x[sel], 0, W - 1), np.clip(y[sel], 0, H - 1)
            base = np.where(p[sel][:, None] > 0, (205, 205, 205), (110, 110, 110)) * fade
            img[ys, xs] = base.astype(np.uint8)
            if label is not None:
                g = label[sel] > 0; blob(img, xs[g], ys[g], tuple(int(c * fade) for c in (60, 200, 90)))
            r = pred[sel]; blob(img, xs[r], ys[r], tuple(int(c * fade) for c in (235, 50, 40)))
        for k in np.nonzero((tfidx <= f) & (tfidx > f - 3))[0]:
            cx, cy = int(round(trk["x"][k])), int(round(trk["y"][k]))
            ys2, xs2 = np.nonzero(ring); ys2, xs2 = ys2 + cy - 11, xs2 + cx - 11
            ok = (ys2 >= 0) & (ys2 < H) & (xs2 >= 0) & (xs2 < W); img[ys2[ok], xs2[ok]] = (240, 190, 60)
        # 2x upscale for legibility
        frames.append(np.repeat(np.repeat(img, 2, 0), 2, 1))
    imageio.mimwrite(a.out + ".mp4", frames, fps=a.fps, codec="libx264", quality=7, macro_block_size=1)
    gif_every = max(1, int(round((1000.0 / a.fps) / a.frame_ms)))
    imageio.mimwrite(a.out + ".gif", frames[::gif_every][: int(a.fps * min(T, 6.0))], fps=min(a.fps, 12), loop=0)
    print(f"wrote {a.out}.mp4 ({nfr} frames, {a.frame_ms:g} ms each) and {a.out}.gif  "
          f"(grey: events, red: detector label, green: ground truth, yellow ring: confirmed track)")


if __name__ == "__main__":
    main()
