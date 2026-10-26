"""实心硬盘 + 大字：把字形中间的缝隙填平，字母占满盘面"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

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


def solid_drive(color, size, close=31):
    """把硬盘字形中间的透明缝填平，得到实心轮廓"""
    im = Image.open(os.path.join(SRC, "hard-drive.png")).convert("RGBA").resize((size, size), Image.LANCZOS)
    a = im.split()[3]
    a = a.filter(ImageFilter.MaxFilter(close))
    a = a.filter(ImageFilter.MinFilter(close))
    out = Image.new("RGBA", im.size, color)
    out.putalpha(a)
    return out


def draw_letter(img, text, color, cx, cy, px):
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(F_BOLD, px)
    box = d.textbbox((0, 0), text, font=f)
    d.text((cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]),
           text, font=f, fill=color)


def design_solid(state, k, size=S, close=31):
    c = GREEN if state == "on" else GRAY
    img = Image.new("RGBA", (size, size), CLEAR)
    n = int(size * 0.96)
    drv = solid_drive(c, n, close)
    ox = (size - n) // 2
    oy = (size - n) // 2
    img.alpha_composite(drv, (ox, oy))
    bb = drv.getbbox()
    cx = ox + (bb[0] + bb[2]) / 2
    cy = oy + (bb[1] + bb[3]) / 2
    draw_letter(img, "D", WHITE, cx, cy, int((bb[3] - bb[1]) * k))
    return img


def design_orig_full(state, k, size=S):
    """对照：原字形 + 大字（会被缝切断）"""
    c = GREEN if state == "on" else GRAY
    img = Image.new("RGBA", (size, size), CLEAR)
    n = int(size * 0.94)
    drv = Image.open(os.path.join(SRC, "hard-drive.png")).convert("RGBA").resize((n, n), Image.LANCZOS)
    tinted = Image.new("RGBA", drv.size, c)
    tinted.putalpha(drv.split()[3])
    ox = (size - n) // 2
    oy = (size - n) // 2
    img.alpha_composite(tinted, (ox, oy))
    bb = tinted.getbbox()
    draw_letter(img, "D", WHITE, ox + (bb[0] + bb[2]) / 2, oy + (bb[1] + bb[3]) / 2,
                int((bb[3] - bb[1]) * k))
    return img


CASES = [
    ("对照：原字形 0.62", lambda s: design_orig_full(s, 0.62)),
    ("实心 + 大字 0.55", lambda s: design_solid(s, 0.55)),
    ("实心 + 大字 0.65", lambda s: design_solid(s, 0.65)),
    ("实心 + 大字 0.75", lambda s: design_solid(s, 0.75)),
]

BIG = 190
W = 200 + BIG * 2 + 300
H = 56 + (BIG + 30) * len(CASES)
sheet = Image.new("RGB", (W, H), (250, 251, 252))
sd = ImageDraw.Draw(sheet)
sd.text((20, 12), "实心硬盘让字母占满盘面", font=ImageFont.truetype(F_CNB, 19), fill=INK)

y = 54
for name, fn in CASES:
    sd.text((20, y + 70), name, font=ImageFont.truetype(F_CN, 13), fill=(70, 78, 90))
    on = fn("on").resize((BIG, BIG), Image.LANCZOS)
    off = fn("off").resize((BIG, BIG), Image.LANCZOS)
    sheet.paste(on, (200, y), on)
    sheet.paste(off, (200 + BIG + 12, y), off)
    xx = 200 + BIG * 2 + 34
    for state in ("on", "off"):
        for size in (48, 32, 24):
            im = fn(state).resize((size, size), Image.LANCZOS)
            sheet.paste(im, (xx, y + 60), im)
            xx += size + 8
        xx += 8
    y += BIG + 30

sheet.save(os.path.join(OUT, "_solid.png"))
print("OK", sheet.size)
