import sys, numpy as np
from PIL import Image, ImageDraw
W, H = 346, 260
files = sys.argv[2:]; out = sys.argv[1]
tiles = []
for f in files:
    ev = np.load(f)["ev"]
    t = ev["t"]; T = t.max()
    for frac in (0.3, 0.7):
        t0 = frac * T
        m = (t >= t0) & (t < t0 + 100)
        img = np.full((H, W, 3), 255, np.uint8)
        e = ev[m]
        bg = e["label"] == 0
        img[e["y"][bg & (e["p"]==1)], e["x"][bg & (e["p"]==1)]] = (90, 90, 90)
        img[e["y"][bg & (e["p"]==0)], e["x"][bg & (e["p"]==0)]] = (170, 170, 170)
        img[e["y"][~bg & (e["p"]==1)], e["x"][~bg & (e["p"]==1)]] = (220, 0, 0)
        img[e["y"][~bg & (e["p"]==0)], e["x"][~bg & (e["p"]==0)]] = (0, 0, 220)
        im = Image.fromarray(img); d = ImageDraw.Draw(im)
        d.text((3, 3), f"{f.split('/')[-1]} t={t0:.0f}ms n={m.sum()} tgt={(~bg).sum()}", fill=(0, 120, 0))
        tiles.append(im)
cols = 4; rows = (len(tiles) + cols - 1) // cols
sheet = Image.new("RGB", (cols * (W + 4), rows * (H + 4)), (0, 0, 0))
for i, im in enumerate(tiles):
    sheet.paste(im, ((i % cols) * (W + 4), (i // cols) * (H + 4)))
sheet.save(out)
