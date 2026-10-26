"""三选一最终对比：跨杠大字 / 实心盘大字 / 右上角角标"""
import os
import numpy as np
from PIL import Image, ImageDraw, ImageFont

SRC = r"C:\Apps\Drive-Toggle\icons\_src"
OUT = os.path.join(SRC, "perdisk")
S = 1024
GREEN = (16, 124, 16, 255)
GRAY = (108, 116, 130, 255)
WHITE = (255, 255, 255, 255)
INK = (28, 34, 44, 255)
CLEAR = (0, 0, 0, 0)
F_BOLD = r"C:\Windows\Fonts\segoeuib.ttf"
F_CN = r"C:\Windows\Fonts\msyh.ttc"
F_CNB = r"C:\Windows\Fonts\msyhbd.ttc"


def alpha_of(size):
    im = Image.open(os.path.join(SRC, "hard-drive.png")).convert("RGBA").resize((size, size), Image.LANCZOS)
    return np.array(im.split()[3], dtype=np.uint8)


def solid_alpha(size, mode="min"):
    a = alpha_of(size).copy()
    counts = (a > 20).sum(axis=1)
    rows = np.where(counts > 0)[0]
    top, bot = rows[0], rows[-1]
    med = np.median(counts[top:bot + 1])
    gap = [y for y in range(top, bot + 1) if counts[y] < med * 0.35]
    if gap:
        runs, s = [], gap[0]
        for i in range(1, len(gap)):
            if gap[i] != gap[i - 1] + 1:
                runs.append((s, gap[i - 1])); s = gap[i]
        runs.append((s, gap[-1]))
        for (g0, g1) in runs:
            ui, di = max(0, g0 - 5), min(a.shape[0] - 1, g1 + 5)
            up, dn = a[ui], a[di]
            fill = np.maximum(up, dn) if mode == "max" else np.minimum(up, dn)
            fill = np.where(fill > 128, 255, 0).astype(np.uint8)
            for y in range(max(0, g0 - 2), min(a.shape[0], g1 + 3)):
                a[y] = fill
    return a


_cache = {}


def tinted(name, color, size):
    im = Image.open(os.path.join(SRC, name)).convert("RGBA").resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", im.size, color)
    out.putalpha(im.split()[3])
    return out


def draw_letter(img, text, color, cx, cy, px):
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(F_BOLD, px)
    box = d.textbbox((0, 0), text, font=f)
    d.text((cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]),
           text, font=f, fill=color)


def p1(state, size=S):
    """原字形 + 跨杠大字（字母压在缝上，连续不断）"""
    c = GREEN if state == "on" else GRAY
    img = Image.new("RGBA", (size, size), CLEAR)
    n = int(size * 0.96)
    d = tinted("hard-drive.png", c, n)
    ox = oy = (size - n) // 2
    img.alpha_composite(d, (ox, oy))
    bb = d.getbbox()
    draw_letter(img, "D", WHITE, ox + (bb[0] + bb[2]) / 2, oy + (bb[1] + bb[3]) / 2,
                int((bb[3] - bb[1]) * 0.62))
    return img


def p2(state, size=S, mode="min"):
    """实心盘 + 大字"""
    c = GREEN if state == "on" else GRAY
    img = Image.new("RGBA", (size, size), CLEAR)
    n = int(size * 0.96)
    key = (n, mode)
    if key not in _cache:
        _cache[key] = Image.fromarray(solid_alpha(n, mode), mode="L")
    d = Image.new("RGBA", (n, n), c)
    d.putalpha(_cache[key])
    ox = oy = (size - n) // 2
    img.alpha_composite(d, (ox, oy))
    bb = d.getbbox()
    draw_letter(img, "D", WHITE, ox + (bb[0] + bb[2]) / 2, oy + (bb[1] + bb[3]) / 2,
                int((bb[3] - bb[1]) * 0.58))
    return img


def c2(state, size=S):
    """右上角角标"""
    c = GREEN if state == "on" else GRAY
    img = Image.new("RGBA", (size, size), CLEAR)
    n = int(size * 0.82)
    d = tinted("hard-drive.png", c, n)
    ox = int((size - n) / 2 - size * 0.05)
    oy = int((size - n) / 2 - size * 0.05)
    img.alpha_composite(d, (ox, oy))
    bd = int(size * 0.36)
    bx, by = int(size * 0.75), int(size * 0.25)
    dr = ImageDraw.Draw(img)
    gap = int(bd * 0.11)
    dr.ellipse([bx - bd // 2 - gap, by - bd // 2 - gap, bx + bd // 2 + gap, by + bd // 2 + gap], fill=CLEAR)
    dr.ellipse([bx - bd // 2, by - bd // 2, bx + bd // 2, by + bd // 2], fill=c)
    draw_letter(img, "D", WHITE, bx, by + size * 0.004, int(bd * 0.80))
    return img


CASES = [
    ("1", "原字形 · 大字跨杠", p1),
    ("2", "实心盘 · 大字", lambda s: p2(s, S, "min")),
    ("3", "右上角角标", c2),
]

BIG = 200
W = 240 + BIG * 2 + 330
H = 60 + (BIG + 34) * len(CASES)
sheet = Image.new("RGB", (W, H), (250, 251, 252))
sd = ImageDraw.Draw(sheet)
sd.text((20, 12), "盘符方案三选一", font=ImageFont.truetype(F_CNB, 19), fill=INK)

y = 58
for key, name, fn in CASES:
    sd.text((20, y + 76), key, font=ImageFont.truetype(F_CNB, 18), fill=INK)
    sd.text((20, y + 104), name, font=ImageFont.truetype(F_CN, 12), fill=(80, 88, 100))
    on = fn("on").resize((BIG, BIG), Image.LANCZOS)
    off = fn("off").resize((BIG, BIG), Image.LANCZOS)
    sheet.paste(on, (240, y), on)
    sheet.paste(off, (240 + BIG + 14, y), off)
    xx = 240 + BIG * 2 + 40
    for state in ("on", "off"):
        for size in (48, 32, 24):
            im = fn(state).resize((size, size), Image.LANCZOS)
            sheet.paste(im, (xx, y + 66), im)
            xx += size + 8
        xx += 10
    y += BIG + 34

sheet.save(os.path.join(OUT, "_three.png"))
print("OK", sheet.size)
