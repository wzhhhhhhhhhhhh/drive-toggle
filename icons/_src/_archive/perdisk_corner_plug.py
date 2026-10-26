"""方案3 增强：右上角盘符角标 + 右下角插头徽标"""
import os
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


def tint(name, color, size):
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


def badge_disc(img, cx, cy, d, fill):
    dr = ImageDraw.Draw(img)
    gap = int(d * 0.12)
    dr.ellipse([cx - d // 2 - gap, cy - d // 2 - gap, cx + d // 2 + gap, cy + d // 2 + gap], fill=CLEAR)
    dr.ellipse([cx - d // 2, cy - d // 2, cx + d // 2, cy + d // 2], fill=fill)


def make(state, size=S, style="color", letter_d=0.32, plug_d=0.30, drive_scale=0.76):
    c = GREEN if state == "on" else GRAY
    nxt = GRAY if state == "on" else GREEN
    plug = "plug-disconnected.png" if state == "on" else "plug-connected.png"
    img = Image.new("RGBA", (size, size), CLEAR)

    n = int(size * drive_scale)
    ox = int((size - n) / 2 - size * 0.04)
    oy = int((size - n) / 2 - size * 0.04)
    img.alpha_composite(tint("hard-drive.png", c, n), (ox, oy))

    # 右上角：盘符
    ld = int(size * letter_d)
    lx, ly = int(size * 0.76), int(size * 0.24)
    if style == "color":
        badge_disc(img, lx, ly, ld, c)
        draw_letter(img, "D", WHITE, lx, ly + size * 0.004, int(ld * 0.80))
    else:
        badge_disc(img, lx, ly, ld, WHITE)
        draw_letter(img, "D", c, lx, ly + size * 0.004, int(ld * 0.80))

    # 右下角：插头（下一步动作）
    pd = int(size * plug_d)
    px_, py_ = int(size * 0.76), int(size * 0.76)
    badge_disc(img, px_, py_, pd, nxt)
    pn = int(pd * 0.62)
    img.alpha_composite(tint(plug, WHITE, pn), (px_ - pn // 2, py_ - pn // 2))
    return img


CASES = [
    ("A", "盘符角标=色底白字", dict(style="color")),
    ("B", "盘符角标=白底色字", dict(style="white")),
]

BIG = 210
W = 220 + BIG * 2 + 330
H = 60 + (BIG + 34) * len(CASES)
sheet = Image.new("RGB", (W, H), (250, 251, 252))
sd = ImageDraw.Draw(sheet)
sd.text((20, 12), "右上角盘符 + 右下角插头", font=ImageFont.truetype(F_CNB, 19), fill=INK)

y = 56
for key, name, kw in CASES:
    sd.text((20, y + 80), key, font=ImageFont.truetype(F_CNB, 18), fill=INK)
    sd.text((20, y + 108), name, font=ImageFont.truetype(F_CN, 12), fill=(80, 88, 100))
    on = make("on", **kw).resize((BIG, BIG), Image.LANCZOS)
    off = make("off", **kw).resize((BIG, BIG), Image.LANCZOS)
    sheet.paste(on, (220, y), on)
    sheet.paste(off, (220 + BIG + 14, y), off)
    xx = 220 + BIG * 2 + 40
    for state in ("on", "off"):
        for size in (48, 32, 24):
            im = make(state, size=size, **kw).resize((size * 2, size * 2), Image.LANCZOS)
            sheet.paste(im, (xx, y + 50), im)
            xx += size * 2 + 8
        xx += 10
    y += BIG + 34

sheet.save(os.path.join(OUT, "_corner_plus_plug.png"))
print("OK", sheet.size)
