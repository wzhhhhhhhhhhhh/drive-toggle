"""对比：字母只占盘面 vs 字母占满整个盘体"""
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
    n = int(size * 0.84)
    ox = int((size - n) / 2 - size * 0.05)
    oy = int((size - n) / 2 - size * 0.05)
    drv = tint("hard-drive.png", c, n)
    img.alpha_composite(drv, (ox, oy))
    bb = drv.getbbox()
    h = bb[3] - bb[1]
    d = ImageDraw.Draw(img)

    if mode == "face":
        px = int(h * 0.62)
        cx = ox + (bb[0] + bb[2]) / 2 - size * 0.03
        cy = oy + bb[1] + h * 0.70
    else:  # body：字母占满盘体
        px = int(h * 0.58)
        cx = ox + (bb[0] + bb[2]) / 2 - size * 0.04
        cy = oy + bb[1] + h * 0.52

    f = ImageFont.truetype(F_BOLD, px)
    box = d.textbbox((0, 0), letter, font=f)
    d.text((cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]),
           letter, font=f, fill=WHITE)

    bd = int(size * 0.28)
    bx, by = int(size * 0.75), int(size * 0.75)
    gap = int(bd * 0.12)
    d.ellipse([bx - bd // 2 - gap, by - bd // 2 - gap, bx + bd // 2 + gap, by + bd // 2 + gap], fill=CLEAR)
    d.ellipse([bx - bd // 2, by - bd // 2, bx + bd // 2, by + bd // 2], fill=nxt)
    pn = int(bd * 0.62)
    img.alpha_composite(tint(plug, WHITE, pn), (bx - pn // 2, by - pn // 2))
    return img


MODES = [("A 盘面字母（现状）", "face"), ("B 盘体字母（更大）", "body")]
BIG = 200
W = 200 + BIG * 2 + 60
H = 210
sheet = Image.new("RGB", (W, H + 150), (250, 251, 252))
sd = ImageDraw.Draw(sheet)
sd.text((20, 12), "盘符放大方式对比", font=ImageFont.truetype(F_CNB, 19), fill=INK)

for i, (name, mode) in enumerate(MODES):
    x = 200 + i * (BIG + 20)
    sd.text((x, 52), name, font=ImageFont.truetype(F_CN, 14), fill=(90, 98, 110))
    for j, state in enumerate(("on", "off")):
        im = make(state, "D", mode).resize((BIG - 20, BIG - 20), Image.LANCZOS)
        sheet.paste(im, (x + j * ((BIG - 20) // 2), 76), im)

# 实际大小
yb = H + 10
sd.text((20, yb), "实际大小 48 / 32 / 24 px", font=ImageFont.truetype(F_CN, 13), fill=(140, 148, 160))
for i, (name, mode) in enumerate(MODES):
    x = 200 + i * (BIG + 20)
    xx = x
    for size in (48, 32, 24):
        s = make("on", "D", mode).resize((size, size), Image.LANCZOS)
        sheet.paste(s, (xx, yb + 24), s)
        xx += size + 14

sheet.save(os.path.join(OUT, "_mode_compare.png"))
print("OK", sheet.size)
