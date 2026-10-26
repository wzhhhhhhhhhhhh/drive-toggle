"""方案2 字号对比：大字 + 48/32/24 的放大预览，判断小尺寸可读性"""
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


def make(state, letter, k, drive_scale=0.84, badge=0.30):
    c = GREEN if state == "on" else GRAY
    nxt = GRAY if state == "on" else GREEN
    plug = "plug-disconnected.png" if state == "on" else "plug-connected.png"
    img = Image.new("RGBA", (S, S), CLEAR)
    n = int(S * drive_scale)
    ox = int((S - n) / 2 - S * 0.05)
    oy = int((S - n) / 2 - S * 0.05)
    drv = tint("hard-drive.png", c, n)
    img.alpha_composite(drv, (ox, oy))
    bb = drv.getbbox()

    d = ImageDraw.Draw(img)
    px = int((bb[3] - bb[1]) * k)
    f = ImageFont.truetype(F_BOLD, px)
    cx = ox + (bb[0] + bb[2]) / 2 - S * 0.03
    cy = oy + bb[1] + (bb[3] - bb[1]) * 0.70
    box = d.textbbox((0, 0), letter, font=f)
    d.text((cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]),
           letter, font=f, fill=WHITE)

    bd = int(S * badge)
    bx, by = int(S * 0.74), int(S * 0.74)
    gap = int(bd * 0.12)
    d.ellipse([bx - bd // 2 - gap, by - bd // 2 - gap, bx + bd // 2 + gap, by + bd // 2 + gap], fill=CLEAR)
    d.ellipse([bx - bd // 2, by - bd // 2, bx + bd // 2, by + bd // 2], fill=nxt)
    pn = int(bd * 0.62)
    img.alpha_composite(tint(plug, WHITE, pn), (bx - pn // 2, by - pn // 2))
    return img


KS = [("0.46", 0.46), ("0.54", 0.54), ("0.62", 0.62)]
SIZES = [48, 32, 24]
ZOOM = 3

BIG = 190
COL = 230
W = 150 + COL * len(KS)
H = 30 + BIG + 40 + sum(s * ZOOM + 34 for s in SIZES) + 30
sheet = Image.new("RGB", (W, H), (250, 251, 252))
sd = ImageDraw.Draw(sheet)
sd.text((20, 12), "方案2 盘符字号对比（字母 D / 已挂载态）", font=ImageFont.truetype(F_CNB, 19), fill=INK)

for i, (name, k) in enumerate(KS):
    x = 150 + i * COL
    sd.text((x + 40, 46), "字号系数 " + name, font=ImageFont.truetype(F_BOLD, 15), fill=(90, 98, 110))
    big = make("on", "D", k).resize((BIG, BIG), Image.LANCZOS)
    sheet.paste(big, (x + 10, 70), big)

y = 70 + BIG + 26
for size in SIZES:
    sd.text((20, y + (size * ZOOM) // 2 - 8), f"{size}px ×{ZOOM}", font=ImageFont.truetype(F_CN, 13), fill=(120, 128, 140))
    for i, (name, k) in enumerate(KS):
        im = make("on", "D", k).resize((size, size), Image.LANCZOS)
        im = im.resize((size * ZOOM, size * ZOOM), Image.NEAREST)
        sheet.paste(im, (150 + i * COL + 20, y), im)
    y += size * ZOOM + 34

sheet.save(os.path.join(OUT, "_tune2.png"))
print("OK", sheet.size)
