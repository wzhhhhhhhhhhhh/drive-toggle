"""新思路：字母占满盘体 / 字母做右上角角标"""
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
    solid = Image.new("RGBA", im.size, color)
    solid.putalpha(im.split()[3])
    return solid


def drive_only(size, state, scale=0.94, dx=0.0, dy=0.0):
    c = GREEN if state == "on" else GRAY
    img = Image.new("RGBA", (size, size), CLEAR)
    n = int(size * scale)
    ox = int((size - n) / 2 + size * dx)
    oy = int((size - n) / 2 + size * dy)
    drv = tint("hard-drive.png", c, n)
    img.alpha_composite(drv, (ox, oy))
    return img, (ox, oy), drv


def draw_letter(img, text, color, cx, cy, px):
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(F_BOLD, px)
    box = d.textbbox((0, 0), text, font=f)
    d.text((cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]),
           text, font=f, fill=color)


# ---------- F：字母占满整个盘体 ----------
def design_full(state, k, size=S):
    img, (ox, oy), drv = drive_only(size, state, scale=0.94)
    bb = drv.getbbox()
    cx = ox + (bb[0] + bb[2]) / 2
    cy = oy + (bb[1] + bb[3]) / 2
    draw_letter(img, "D", WHITE, cx, cy, int((bb[3] - bb[1]) * k))
    return img


# ---------- C1：右上角圆形角标（白底 + 状态色字母） ----------
def design_c1(state, size=S):
    img, (ox, oy), drv = drive_only(size, state, scale=0.82, dx=-0.05, dy=-0.05)
    c = GREEN if state == "on" else GRAY
    d = ImageDraw.Draw(img)
    bd = int(size * 0.34)
    bx, by = int(size * 0.74), int(size * 0.26)
    gap = int(bd * 0.11)
    d.ellipse([bx - bd // 2 - gap, by - bd // 2 - gap, bx + bd // 2 + gap, by + bd // 2 + gap], fill=CLEAR)
    d.ellipse([bx - bd // 2, by - bd // 2, bx + bd // 2, by + bd // 2], fill=WHITE)
    draw_letter(img, "D", c, bx, by + size * 0.004, int(bd * 0.80))
    return img


# ---------- C2：右上角圆形角标（状态色底 + 白字母） ----------
def design_c2(state, size=S):
    img, (ox, oy), drv = drive_only(size, state, scale=0.82, dx=-0.05, dy=-0.05)
    c = GREEN if state == "on" else GRAY
    d = ImageDraw.Draw(img)
    bd = int(size * 0.34)
    bx, by = int(size * 0.74), int(size * 0.26)
    gap = int(bd * 0.11)
    d.ellipse([bx - bd // 2 - gap, by - bd // 2 - gap, bx + bd // 2 + gap, by + bd // 2 + gap], fill=CLEAR)
    d.ellipse([bx - bd // 2, by - bd // 2, bx + bd // 2, by + bd // 2], fill=c)
    draw_letter(img, "D", WHITE, bx, by + size * 0.004, int(bd * 0.80))
    return img


# ---------- C3：右上角圆角方形角标 ----------
def design_c3(state, size=S):
    img, (ox, oy), drv = drive_only(size, state, scale=0.82, dx=-0.05, dy=-0.05)
    c = GREEN if state == "on" else GRAY
    d = ImageDraw.Draw(img)
    bd = int(size * 0.34)
    bx, by = int(size * 0.73), int(size * 0.27)
    half = bd // 2
    gap = int(bd * 0.11)
    d.rounded_rectangle([bx - half - gap, by - half - gap, bx + half + gap, by + half + gap],
                        radius=int((bd + gap * 2) * 0.30), fill=CLEAR)
    d.rounded_rectangle([bx - half, by - half, bx + half, by + half],
                        radius=int(bd * 0.26), fill=c)
    draw_letter(img, "D", WHITE, bx, by + size * 0.004, int(bd * 0.74))
    return img


DESIGNS = [
    ("F1", "字母占满盘体（0.62）", lambda s: design_full(s, 0.62)),
    ("F2", "字母占满盘体（0.74）", lambda s: design_full(s, 0.74)),
    ("C1", "右上角标 · 白底", design_c1),
    ("C2", "右上角标 · 色底", design_c2),
    ("C3", "右上角标 · 方块", design_c3),
]

BIG = 180
W = 200 + BIG + 340
H = 60 + (BIG + 34) * len(DESIGNS)
sheet = Image.new("RGB", (W, H), (250, 251, 252))
sd = ImageDraw.Draw(sheet)
sd.text((20, 12), "字母占满盘体 / 右上角角标", font=ImageFont.truetype(F_CNB, 19), fill=INK)

y = 56
for key, name, fn in DESIGNS:
    sd.text((20, y + 70), key, font=ImageFont.truetype(F_CNB, 17), fill=INK)
    sd.text((20, y + 96), name, font=ImageFont.truetype(F_CN, 12), fill=(90, 98, 110))
    on = fn("on").resize((BIG, BIG), Image.LANCZOS)
    off = fn("off").resize((BIG, BIG), Image.LANCZOS)
    sheet.paste(on, (200, y), on)
    sheet.paste(off, (200 + BIG + 14, y), off)
    # 1:1
    xx = 200 + BIG * 2 + 40
    for state in ("on", "off"):
        for size in (48, 32, 24):
            im = fn(state).resize((size, size), Image.LANCZOS)
            sheet.paste(im, (xx, y + 40), im)
            xx += size + 10
        xx += 10
    y += BIG + 34

sheet.save(os.path.join(OUT, "_variants.png"))
print("OK", sheet.size)
