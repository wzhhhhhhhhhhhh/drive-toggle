"""实心硬盘 v2：只填平中间那条横缝，保留外轮廓"""
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


def solid_alpha(size):
    """把 hard-drive.png 的 alpha 中间横缝填平"""
    im = Image.open(os.path.join(SRC, "hard-drive.png")).convert("RGBA").resize((size, size), Image.LANCZOS)
    a = np.array(im.split()[3], dtype=np.uint8)
    counts = (a > 20).sum(axis=1)
    rows = np.where(counts > 0)[0]
    top, bot = rows[0], rows[-1]
    med = np.median(counts[top:bot + 1])
    gap = [y for y in range(top, bot + 1) if counts[y] < med * 0.35]
    if gap:
        # 找连续段，用上下两行逐列合并填充
        runs, s = [], gap[0]
        for i in range(1, len(gap)):
            if gap[i] != gap[i - 1] + 1:
                runs.append((s, gap[i - 1])); s = gap[i]
        runs.append((s, gap[-1]))
        for (g0, g1) in runs:
            ui = max(0, g0 - 5)
            di = min(a.shape[0] - 1, g1 + 5)
            up = a[ui] if ui < g0 else a[di]
            dn = a[di] if di > g1 else a[ui]
            fill = np.maximum(up, dn)
            fill = np.where(fill > 128, 255, 0).astype(np.uint8)
            for y in range(max(0, g0 - 2), min(a.shape[0], g1 + 3)):
                a[y] = fill
    return Image.fromarray(a, mode="L")


_alpha_cache = {}


def get_drive(color, size):
    key = size
    if key not in _alpha_cache:
        _alpha_cache[key] = solid_alpha(size)
    img = Image.new("RGBA", (size, size), color)
    img.putalpha(_alpha_cache[key])
    return img


def draw_letter(img, text, color, cx, cy, px):
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(F_BOLD, px)
    box = d.textbbox((0, 0), text, font=f)
    d.text((cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]),
           text, font=f, fill=color)


def make(state, k, size=S, letter="D", scale=0.96):
    c = GREEN if state == "on" else GRAY
    img = Image.new("RGBA", (size, size), CLEAR)
    n = int(size * scale)
    ox, oy = (size - n) // 2, (size - n) // 2
    drv = get_drive(c, n)
    img.alpha_composite(drv, (ox, oy))
    bb = drv.getbbox()
    draw_letter(img, letter, WHITE,
                ox + (bb[0] + bb[2]) / 2, oy + (bb[1] + bb[3]) / 2,
                int((bb[3] - bb[1]) * k))
    return img


CASES = [("0.50", 0.50), ("0.58", 0.58), ("0.66", 0.66)]
BIG = 190
W = 210 + BIG * 2 + 300
H = 56 + (BIG + 30) * len(CASES)
sheet = Image.new("RGB", (W, H), (250, 251, 252))
sd = ImageDraw.Draw(sheet)
sd.text((20, 12), "实心硬盘 + 字母占满盘面", font=ImageFont.truetype(F_CNB, 19), fill=INK)

y = 54
for name, k in CASES:
    sd.text((20, y + 74), "字号 " + name, font=ImageFont.truetype(F_CN, 13), fill=(70, 78, 90))
    on = make("on", k).resize((BIG, BIG), Image.LANCZOS)
    off = make("off", k).resize((BIG, BIG), Image.LANCZOS)
    sheet.paste(on, (210, y), on)
    sheet.paste(off, (210 + BIG + 12, y), off)
    xx = 210 + BIG * 2 + 34
    for state in ("on", "off"):
        for size in (48, 32, 24):
            im = make(state, k).resize((size, size), Image.LANCZOS)
            sheet.paste(im, (xx, y + 62), im)
            xx += size + 8
        xx += 8
    y += BIG + 30

sheet.save(os.path.join(OUT, "_solid2.png"))
print("OK", sheet.size)
