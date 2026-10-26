"""最终确定：方案2 + 放大盘符（k=0.62）+ 徽标略缩到 0.28"""
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

K = 0.62
BADGE = 0.28
DRIVE = 0.84


def tint(name, color, size):
    im = Image.open(os.path.join(SRC, name)).convert("RGBA").resize((size, size), Image.LANCZOS)
    solid = Image.new("RGBA", im.size, color)
    solid.putalpha(im.split()[3])
    return solid


def make(state, letter=None, size=S, k=K, badge=BADGE):
    c = GREEN if state == "on" else GRAY
    nxt = GRAY if state == "on" else GREEN
    plug = "plug-disconnected.png" if state == "on" else "plug-connected.png"
    img = Image.new("RGBA", (size, size), CLEAR)
    if letter is None:
        n = int(size * 0.94)
        img.alpha_composite(tint("hard-drive.png", c, n), ((size - n) // 2, (size - n) // 2))
        d = ImageDraw.Draw(img)
        bd = int(size * 0.34)
        bx, by = int(size * 0.72), int(size * 0.72)
    else:
        n = int(size * DRIVE)
        ox = int((size - n) / 2 - size * 0.05)
        oy = int((size - n) / 2 - size * 0.05)
        drv = tint("hard-drive.png", c, n)
        img.alpha_composite(drv, (ox, oy))
        bb = drv.getbbox()
        d = ImageDraw.Draw(img)
        px = max(6, int((bb[3] - bb[1]) * k))
        f = ImageFont.truetype(F_BOLD, px)
        cx = ox + (bb[0] + bb[2]) / 2 - size * 0.03
        cy = oy + bb[1] + (bb[3] - bb[1]) * 0.70
        box = d.textbbox((0, 0), letter, font=f)
        d.text((cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]),
               letter, font=f, fill=WHITE)
        bd = int(size * badge)
        bx, by = int(size * 0.75), int(size * 0.75)
    gap = int(bd * 0.12)
    d.ellipse([bx - bd // 2 - gap, by - bd // 2 - gap, bx + bd // 2 + gap, by + bd // 2 + gap], fill=CLEAR)
    d.ellipse([bx - bd // 2, by - bd // 2, bx + bd // 2, by + bd // 2], fill=nxt)
    pn = int(bd * 0.62)
    img.alpha_composite(tint(plug, WHITE, pn), (bx - pn // 2, by - pn // 2))
    return img


cols = [("总开关", None), ("D 盘", "D"), ("E 盘", "E"), ("F 盘", "F"), ("G 盘", "G")]
CELL, PAD = 176, 24
W = PAD * 2 + CELL * len(cols)
ROW = 190
sheet = Image.new("RGB", (W, 86 + ROW * 2 + 70), (250, 251, 252))
sd = ImageDraw.Draw(sheet)
sd.text((PAD, 14), "最终方案：方案2 + 放大盘符（0.62）", font=ImageFont.truetype(F_CNB, 19), fill=INK)
for i, (name, _) in enumerate(cols):
    sd.text((PAD + i * CELL + 12, 58), name, font=ImageFont.truetype(F_CN, 14), fill=(90, 98, 110))

for r, state in enumerate(("on", "off")):
    y = 86 + r * ROW
    sd.text((PAD, y + 60), "已挂载" if state == "on" else "已卸载", font=ImageFont.truetype(F_CN, 13), fill=(120, 128, 140))
    for i, (name, letter) in enumerate(cols):
        im = make(state, letter)
        big = im.resize((CELL - 36, CELL - 36), Image.LANCZOS)
        sheet.paste(big, (PAD + i * CELL + 18, y), big)

# 小尺寸条
yb = 86 + ROW * 2 + 6
sd.text((PAD, yb), "实际大小：48 / 32 / 24 px（1:1，未缩放）", font=ImageFont.truetype(F_CN, 12), fill=(140, 148, 160))
for i, (name, letter) in enumerate(cols):
    x = PAD + i * CELL + 18
    xx = x
    for size in (48, 32, 24):
        s = make("on", letter).resize((size, size), Image.LANCZOS)
        sheet.paste(s, (xx, yb + 22), s)
        xx += size + 12

sheet.save(os.path.join(OUT, "_final_perdisk.png"))
print("OK", sheet.size)
