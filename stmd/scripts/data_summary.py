import sys, glob, numpy as np
tot = 0
for f in sorted(glob.glob(sys.argv[1] + "/*.npz")):
    ev = np.load(f, allow_pickle=False)["ev"]
    x, y, t, p, lab, nm = (ev[k] for k in ("x", "y", "t", "p", "label", "name"))
    dur = t.max() - t.min()
    pos = lab > 0
    ids = np.unique(nm[pos]).tolist()
    # target bbox size per 10 ms window
    sizes = []
    for w0 in np.arange(t.min(), t.max(), 10.0):
        m = pos & (t >= w0) & (t < w0 + 10)
        if m.sum() > 3:
            sizes.append(((x[m].max() - x[m].min() + 1), (y[m].max() - y[m].min() + 1)))
    s = np.array(sizes) if sizes else np.zeros((1, 2))
    tot += len(ev)
    print(f"{f.split('/')[-1]} n={len(ev):>7} dur={dur:7.0f}ms x[{x.min()},{x.max()}] y[{y.min()},{y.max()}] "
          f"tgt={pos.sum():>6} ({100*pos.mean():5.2f}%) ids={ids} on-frac={p[pos].mean() if pos.any() else 0:.2f} "
          f"bbox10ms med={np.median(s[:,0]):.0f}x{np.median(s[:,1]):.0f} win_with_tgt={len(sizes)}/{int(dur//10)+1} sorted={bool(np.all(np.diff(t)>=0))}")
print("total events", tot)
