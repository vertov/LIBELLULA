import sys, json
sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.dirname(__import__("os").path.abspath(__file__))))
import numpy as np
from PIL import Image, ImageDraw
from libstmd import data, model
W, H = 346, 260
out = sys.argv[1]; P = model.Params(**json.loads(sys.argv[2])); files = sys.argv[3:]
tiles = []
for f in files:
    s = data.load(f); o = model.run(s, P); T = s.t_us.max()
    for frac in (0.25, 0.5, 0.75):
        t0 = frac * T; m = (s.t_us >= t0) & (s.t_us < t0 + 200_000)
        img = np.full((H, W, 3), 255, np.uint8)
        g = s.label > 0; pr = o["pred"]
        for msk, col in ((m & ~g & ~pr, (190, 190, 190)), (m & g & ~pr, (0, 0, 255)),
                         (m & ~g & pr, (255, 140, 0)), (m & g & pr, (0, 170, 0))):
            img[s.y[msk], s.x[msk]] = col
        im = Image.fromarray(img); d = ImageDraw.Draw(im)
        d.text((3, 3), f"{s.name} t={t0/1000:.0f}ms 200ms", fill=(0, 0, 0)); tiles.append(im)
cols = 3; rows = (len(tiles) + cols - 1) // cols
sheet = Image.new("RGB", (cols * (W + 4), rows * (H + 4)), (0, 0, 0))
for i, im in enumerate(tiles): sheet.paste(im, ((i % cols) * (W + 4), (i // cols) * (H + 4)))
sheet.save(out)
