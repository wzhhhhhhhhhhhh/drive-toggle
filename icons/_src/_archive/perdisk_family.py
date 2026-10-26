"""生成「整套图标」示意：总开关（无盘符）+ 各盘（D/E/F/G）"""
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
F_CN = r"C:\Windows\Fonts\msyhbd.ttc"
F_CN2 = r"C:\Windows\Fonts\msyh.ttc"


def tint(name, color, size):
    im = Image.open(os.path.join(SRC, name)).convert("RGBA").resize((size, size), Image.LANCZOS)
    solid = Image.new("RGBA", im.size, color)
    solid.putalpha(im.split()[3])
    return solid


def draw_letter(img, text, color, cx, cy, px):
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(F_BOLD, px)
    box = d.textbbox((0, 0), text, font=f)
    w, h = box[2] - box[0], box[3] - box[1]
    d.text((cx - w / 2 - box[0], cy - h / 2 - box[1]), text, font=f, fill=color)


def make(state, letter=None, with_plug=False, size=S):
    c = GREEN if state == "on" else GRAY
    nxt = GRAY if state == "on" else GREEN
    plug = "plug-disconnected.png" if state == "on" else "plug-connected.png"
    img = Image.new("RGBA", (size, size), CLEAR)
    scale = 0.80 if with_plug else 0.94
    dx = -0.05 if with_plug else 0.0
    dy = -0.05 if with_plug else 0.0
    n = int(size * scale)
    ox, oy = int((size - n) / 2 + size * dx), int((size - n) / 2 + size * dy)
    drv = tint("hard-drive.png", c, n)
    img.alpha_composite(drv, (ox, oy))
    bb = drv.getbbox()
    if letter:
        cx = ox + (bb[0] + bb[2]) / 2
        cy = oy + bb[1] + (bb[3] - bb[1]) * 0.70
        draw_letter(img, letter, WHITE, cx, cy, int((bb[3] - bb[1]) * (0.40 if with_plug else 0.36)))
    if with_plug:
        d = ImageDraw.Draw(img)
        bd = int(size * 0.34)
        bx, by = int(size * 0.72), int(size * 0.72)
        gap = int(bd * 0.13)
        d.ellipse([bx - bd // 2 - gap, by - bd // 2 - gap, bx + bd // 2 + gap, by + bd // 2 + gap], fill=CLEAR)
        d.ellipse([bx - bd // 2, by - bd // 2, bx + bd // 2, by + bd // 2], fill=nxt)
        pn = int(bd * 0.62)
        img.alpha_composite(tint(plug, WHITE, pn), (bx - pn // 2, by - pn // 2))
    return img


for name, with_plug in (("v1", False), ("v2", True)):
    CELL, PAD, TOP = 170, 26, 120
    cols = ["总开关", "D 盘", "E 盘", "F 盘", "G 盘"]
    W = PAD * 2 + CELL * len(cols)
    H = TOP + (CELL + 30) * 2 + 20
    sheet = Image.new("RGB", (W, H), (250, 251, 252))
    sd = ImageDraw.Draw(sheet)
    title = "方案 1：盘符压盘面" if not with_plug else "方案 2：盘面字母 + 插头徽标"
    sd.text((PAD, 16), "整套图标 · " + title, font=ImageFont.truetype(F_CN, 20), fill=INK)
    for i, c in enumerate(cols):
        sd.text((PAD + i * CELL + 10, 60), c, font=ImageFont.truetype(F_CN2, 14), fill=(90, 98, 110))
    for r, state in enumerate(("on", "off")):
        y = TOP + r * (CELL + 30)
        sd.text((PAD, y + 54), "已挂载" if state == "on" else "已卸载",
                font=ImageFont.truetype(F_CN2, 13), fill=(120, 128, 140))
        for i, _ in enumerate(cols):
            letter = None if i == 0 else cols[i][0]
            im = make(state, letter, with_plug)
            big = im.resize((CELL - 30, CELL - 30), Image.LANCZOS)
            sheet.paste(big, (PAD + 40 + i * CELL, y), big)
    sheet.save(os.path.join(OUT, f"_family_{name}.png"))
    print("OK", name, sheet.size)
