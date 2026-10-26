"""最终对比：A 盘面字母+徽标 / C 盘面大字无徽标（小尺寸更清楚）"""
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


def make(state, letter, mode, size=S):
    c = GREEN if state == "on" else GRAY
    nxt = GRAY if state == "on" else GREEN
    plug = "plug-disconnected.png" if state == "on" else "plug-connected.png"
    img = Image.new("RGBA", (size, size), CLEAR)
    with_badge = (mode == "A")
    scale = 0.84 if with_badge else 0.94
    ox = int((size - size * scale) / 2 - (size * 0.05 if with_badge else 0))
    oy = int((size - size * scale) / 2 - (size * 0.05 if with_badge else 0))
    drv = tint("hard-drive.png", c, int(size * scale))
    img.alpha_composite(drv, (ox, oy))
    bb = drv.getbbox()
    h = bb[3] - bb[1]
    d = ImageDraw.Draw(img)
    px = int(h * (0.62 if with_badge else 0.80))
    cx = ox + (bb[0] + bb[2]) / 2 - (size * 0.03 if with_badge else 0)
    cy = oy + bb[1] + h * 0.70
    f = ImageFont.truetype(F_BOLD, px)
    box = d.textbbox((0, 0), letter, font=f)
    d.text((cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]),
           letter, font=f, fill=WHITE)
    if with_badge:
        bd = int(size * 0.28)
        bx, by = int(size * 0.75), int(size * 0.75)
        gap = int(bd * 0.12)
        d.ellipse([bx - bd // 2 - gap, by - bd // 2 - gap, bx + bd // 2 + gap, by + bd // 2 + gap], fill=CLEAR)
        d.ellipse([bx - bd // 2, by - bd // 2, bx + bd // 2, by + bd // 2], fill=nxt)
        pn = int(bd * 0.62)
        img.alpha_composite(tint(plug, WHITE, pn), (bx - pn // 2, by - pn // 2))
    return img


MODES = [("A  带插头徽标", "A"), ("C  不带徽标，字母更大", "C")]
BIG, ZOOM = 180, 3
W = 170 + 400 * 2 + 40
H = 340
sheet = Image.new("RGB", (W, H + 190), (250, 251, 252))
sd = ImageDraw.Draw(sheet)
sd.text((20, 12), "最终对比：字母大小 vs 是否保留插头徽标", font=ImageFont.truetype(F_CNB, 19), fill=INK)

for i, (name, mode) in enumerate(MODES):
    x = 170 + i * 400
    sd.text((x, 52), name, font=ImageFont.truetype(F_CN, 14), fill=(90, 98, 110))
    im = make("on", "D", mode).resize((BIG, BIG), Image.LANCZOS)
    sheet.paste(im, (x, 78), im)

yb = 78 + BIG + 30
sd.text((20, yb), "实际大小 ×3 放大：48 / 32 / 24", font=ImageFont.truetype(F_CN, 13), fill=(140, 148, 160))
for i, (name, mode) in enumerate(MODES):
    x = 170 + i * 400
    offsets = (0, 170, 275)
    for k, size in enumerate((48, 32, 24)):
        s = make("on", "D", mode).resize((size * ZOOM, size * ZOOM), Image.LANCZOS)
        sheet.paste(s, (x + offsets[k], yb + 26), s)

sheet.save(os.path.join(OUT, "_final2.png"))
print("OK", sheet.size)
