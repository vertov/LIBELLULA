"""Contact sheet and filmstrip JPEGs (PIL)."""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from .probe import sec_to_hms


def _font(size: int):
    for name in ("DejaVuSans.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/System/Library/Fonts/Helvetica.ttc",
                 "/System/Library/Fonts/Supplemental/Arial.ttf", "/Library/Fonts/Arial.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except Exception:
            continue
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def contact_sheet(shots: list[dict], thumb_dir: Path, dst: Path, title: str, subtitle: str = "",
                  cols: int = 6, cell_w: int = 240) -> Path:
    cell_h = int(cell_w * 9 / 16)
    cap_h = 34
    pad = 6
    header = 56
    rows = max(1, (len(shots) + cols - 1) // cols)
    W = cols * (cell_w + pad) + pad
    H = header + rows * (cell_h + cap_h + pad) + pad
    sheet = Image.new("RGB", (W, H), (24, 24, 26))
    draw = ImageDraw.Draw(sheet)
    f_title, f_sub, f_cap, f_small = _font(20), _font(13), _font(13), _font(11)
    draw.text((pad + 4, 8), title, fill=(240, 240, 240), font=f_title)
    if subtitle:
        draw.text((pad + 4, 34), subtitle, fill=(170, 170, 170), font=f_sub)
    for i, s in enumerate(shots):
        r, c = divmod(i, cols)
        x = pad + c * (cell_w + pad)
        y = header + r * (cell_h + cap_h + pad)
        kf = s.get("key_frame")
        try:
            im = Image.open(thumb_dir / kf).convert("RGB") if kf else None
        except Exception:
            im = None
        if im is None:
            im = Image.new("RGB", (cell_w, cell_h), (60, 60, 60))
        im.thumbnail((cell_w, cell_h))
        ox = x + (cell_w - im.width) // 2
        sheet.paste(im, (ox, y))
        # colour chips
        for k, col in enumerate((s.get("colors") or [])[:5]):
            try:
                rgb = tuple(int(col["hex"][j:j + 2], 16) for j in (1, 3, 5))
            except Exception:
                continue
            draw.rectangle([x + k * 12, y + cell_h - 8, x + k * 12 + 11, y + cell_h - 1], fill=rgb)
        cap1 = f"#{s['idx'] + 1:03d}  {s.get('start_tc') or sec_to_hms(s['start_sec'])}"
        cap2 = f"{s['duration_sec']:.2f}s  {s.get('in_type', '')}"
        extra = s.get("shot_scale") or s.get("camera_motion") or ""
        if extra:
            cap2 += f"  {extra}"
        draw.text((x, y + cell_h + 2), cap1, fill=(230, 230, 230), font=f_cap)
        draw.text((x, y + cell_h + 18), cap2, fill=(160, 160, 160), font=f_small)
    dst.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(dst, quality=88)
    return dst


def filmstrip(frame_names: list[str], thumb_dir: Path, dst: Path, gap: int = 4) -> Path | None:
    ims = []
    for n in frame_names:
        try:
            ims.append(Image.open(thumb_dir / n).convert("RGB"))
        except Exception:
            pass
    if not ims:
        return None
    h = min(im.height for im in ims)
    ims = [im.resize((int(im.width * h / im.height), h)) for im in ims]
    W = sum(im.width for im in ims) + gap * (len(ims) - 1)
    strip = Image.new("RGB", (W, h), (0, 0, 0))
    x = 0
    for im in ims:
        strip.paste(im, (x, 0))
        x += im.width + gap
    strip.save(dst, quality=85)
    return dst
