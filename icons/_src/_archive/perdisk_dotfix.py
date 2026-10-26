"""方案A 修正版：抹掉硬盘指示灯圆点，右上角盘符 + 右下角插头"""
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


def glyph_alpha(size):
    """取硬盘 alpha，并填掉内部的封闭孔洞（指示灯圆点）"""
    im = Image.open(os.path.join(SRC, "hard-drive.png")).convert("RGBA").resize((size, size), Image.LANCZOS)
    a = np.array(im.split()[3], dtype=np.uint8)
    shape = a > 20
    # 从边缘出发，逐轮向未填充的背景扩散，得到"外部背景"
    outside = np.zeros_like(shape)
    outside[0, :] = ~shape[0, :]
    outside[-1, :] = ~shape[-1, :]
    outside[:, 0] = ~shape[:, 0]
    outside[:, -1] = ~shape[:, -1]
    for _ in range(size * 2):
        new_out = outside.copy()
        new_out[1:, :] |= outside[:-1, :] & ~shape[1:, :]
        new_out[:-1, :] |= outside[1:, :] & ~shape[:-1, :]
        new_out[:, 1:] |= outside[:, :-1] & ~shape[:, 1:]
        new_out[:, :-1] |= outside[:, 1:] & ~shape[:, :-1]
        if np.array_equal(new_out, outside):
            break
        outside = new_out
    holes = (~shape) & (~outside)     # 内部孔洞（指示灯圆点）
    a2 = a.copy()
    a2[holes] = 255
    return a2


_alpha_cache = {}


def drive(color, size):
    if size not in _alpha_cache:
        _alpha_cache[size] = glyph_alpha(size)
    img = Image.new("RGBA", (size, size), color)
    img.putalpha(Image.fromarray(_alpha_cache[size], mode="L"))
    return img


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


def disc(img, cx, cy, d, fill):
    dr = ImageDraw.Draw(img)
    gap = int(d * 0.12)
    dr.ellipse([cx - d // 2 - gap, cy - d // 2 - gap, cx + d // 2 + gap, cy + d // 2 + gap], fill=CLEAR)
    dr.ellipse([cx - d // 2, cy - d // 2, cx + d // 2, cy + d // 2], fill=fill)


def make(state, size=S, letter="D", with_plug=True):
    c = GREEN if state == "on" else GRAY
    nxt = GRAY if state == "on" else GREEN
    plug = "plug-disconnected.png" if state == "on" else "plug-connected.png"
    img = Image.new("RGBA", (size, size), CLEAR)

    n = int(size * 0.76)
    ox = int((size - n) / 2 - size * 0.04)
    oy = int((size - n) / 2 - size * 0.04)
    img.alpha_composite(drive(c, n), (ox, oy))

    ld = int(size * 0.32)
    lx, ly = int(size * 0.76), int(size * 0.24)
    disc(img, lx, ly, ld, c)
    draw_letter(img, letter, WHITE, lx, ly + size * 0.004, int(ld * 0.80))

    if with_plug:
        pd = int(size * 0.30)
        px_, py_ = int(size * 0.76), int(size * 0.76)
        disc(img, px_, py_, pd, nxt)
        pn = int(pd * 0.62)
        img.alpha_composite(tint(plug, WHITE, pn), (px_ - pn // 2, py_ - pn // 2))
    return img


# ---- 对比：修正前 vs 修正后 ----
def make_unfixed(state, size=S):
    """不抹点的版本，用于对比"""
    c = GREEN if state == "on" else GRAY
    nxt = GRAY if state == "on" else GREEN
    plug = "plug-disconnected.png" if state == "on" else "plug-connected.png"
    img = Image.new("RGBA", (size, size), CLEAR)
    n = int(size * 0.76)
    ox = int((size - n) / 2 - size * 0.04)
    oy = int((size - n) / 2 - size * 0.04)
    img.alpha_composite(tint("hard-drive.png", c, n), (ox, oy))
    ld = int(size * 0.32)
    lx, ly = int(size * 0.76), int(size * 0.24)
    disc(img, lx, ly, ld, c)
    draw_letter(img, "D", WHITE, lx, ly + size * 0.004, int(ld * 0.80))
    pd = int(size * 0.30)
    px_, py_ = int(size * 0.76), int(size * 0.76)
    disc(img, px_, py_, pd, nxt)
    pn = int(pd * 0.62)
    img.alpha_composite(tint(plug, WHITE, pn), (px_ - pn // 2, py_ - pn // 2))
    return img


BIG = 200
sheet = Image.new("RGB", (860, 620), (250, 251, 252))
sd = ImageDraw.Draw(sheet)
sd.text((20, 12), "抹掉指示灯圆点前后对比", font=ImageFont.truetype(F_CNB, 18), fill=INK)

pairs = [("修正前", make_unfixed), ("修正后", make)]
y = 56
for name, fn in pairs:
    sd.text((20, y + 80), name, font=ImageFont.truetype(F_CN, 14), fill=(70, 78, 90))
    on = fn("on").resize((BIG, BIG), Image.LANCZOS)
    off = fn("off").resize((BIG, BIG), Image.LANCZOS)
    sheet.paste(on, (140, y), on)
    sheet.paste(off, (140 + BIG + 14, y), off)
    xx = 140 + BIG * 2 + 50
    for state in ("on", "off"):
        for size in (48, 32):
            im = fn(state).resize((size, size), Image.LANCZOS)
            sheet.paste(im, (xx, y + 76), im)
            xx += size + 10
        xx += 10
    y += BIG + 30

sheet.save(os.path.join(OUT, "_dotfix.png"))
print("OK", sheet.size)
