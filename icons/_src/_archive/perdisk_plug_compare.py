"""精确对比插头徽标：按各自中心裁剪放大，含 on/off 两态"""
import os
import io
import struct
from PIL import Image, ImageDraw, ImageFont

SRC = r"C:\Apps\Drive-Toggle\icons\_src"
ICONS = r"C:\Apps\Drive-Toggle\icons"
OUT = os.path.join(SRC, "perdisk")
F_CN = r"C:\Windows\Fonts\msyh.ttc"
F_CNB = r"C:\Windows\Fonts\msyhbd.ttc"
GREEN = (16, 124, 16, 255)
GRAY = (108, 116, 130, 255)
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)


def largest_frame(path):
    data = open(path, "rb").read()
    cnt = struct.unpack("<H", data[4:6])[0]
    best = None
    for i in range(cnt):
        off = 6 + i * 16
        w, h, _, _, _, _, size, o = struct.unpack("<BBBBHHII", data[off:off + 16])
        w = 256 if w == 0 else w
        if best is None or w > best[0]:
            best = (w, data[o:o + size])
    return Image.open(io.BytesIO(best[1])).convert("RGBA")


def tint(name, color, size):
    im = Image.open(os.path.join(SRC, name)).convert("RGBA").resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", im.size, color)
    out.putalpha(im.split()[3])
    return out


def draw_letter(img, text, color, cx, cy, px):
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(r"C:\Windows\Fonts\segoeuib.ttf", px)
    box = d.textbbox((0, 0), text, font=f)
    d.text((cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]),
           text, font=f, fill=color)


def badge_disc(img, cx, cy, d, fill):
    dr = ImageDraw.Draw(img)
    gap = int(d * 0.12)
    dr.ellipse([cx - d // 2 - gap, cy - d // 2 - gap, cx + d // 2 + gap, cy + d // 2 + gap], fill=CLEAR)
    dr.ellipse([cx - d // 2, cy - d // 2, cx + d // 2, cy + d // 2], fill=fill)


def new_a(state, size=1024):
    c = GREEN if state == "on" else GRAY
    nxt = GRAY if state == "on" else GREEN
    plug = "plug-disconnected.png" if state == "on" else "plug-connected.png"
    img = Image.new("RGBA", (size, size), CLEAR)
    n = int(size * 0.76)
    ox = int((size - n) / 2 - size * 0.04); oy = int((size - n) / 2 - size * 0.04)
    img.alpha_composite(tint("hard-drive.png", c, n), (ox, oy))
    ld = int(size * 0.32); lx, ly = int(size * 0.76), int(size * 0.24)
    badge_disc(img, lx, ly, ld, c)
    draw_letter(img, "D", WHITE, lx, ly + size * 0.004, int(ld * 0.80))
    pd = int(size * 0.30); px_, py_ = int(size * 0.76), int(size * 0.76)
    badge_disc(img, px_, py_, pd, nxt)
    pn = int(pd * 0.62)
    img.alpha_composite(tint(plug, WHITE, pn), (px_ - pn // 2, py_ - pn // 2))
    return img


def crop_at(im, cx, cy, d, out_px=300):
    """以 (cx,cy) 为中心、边长 = d*1.45 裁剪并放大"""
    W = im.size[0]
    half = int(W * d * 1.45 / 2)
    X, Y = int(W * cx), int(W * cy)
    box = (max(0, X - half), max(0, Y - half), min(W, X + half), min(W, Y + half))
    return im.crop(box).resize((out_px, out_px), Image.LANCZOS)


rows = []
for state, label in (("on", "已挂载（绿盘 + 灰插头）"), ("off", "已卸载（灰盘 + 绿插头）")):
    old = largest_frame(os.path.join(ICONS, f"toggle-{state}.ico"))
    new = new_a(state).resize((256, 256), Image.LANCZOS)
    rows.append((label, crop_at(old, 0.70, 0.70, 0.36), crop_at(new, 0.76, 0.76, 0.30)))

sheet = Image.new("RGB", (760, 800), (250, 251, 252))
sd = ImageDraw.Draw(sheet)
sd.text((20, 12), "插头徽标放大对比：左=当前在用　右=方案A", font=ImageFont.truetype(F_CNB, 18), fill=(28, 34, 44))
y = 54
for label, o, n in rows:
    sd.text((20, y + 10), label, font=ImageFont.truetype(F_CN, 14), fill=(70, 78, 90))
    sheet.paste(o, (30, y + 34), o)
    sheet.paste(n, (400, y + 34), n)
    sd.text((30, y + 340), "toggle-" + ("on" if "挂载（" in label else "off") + ".ico", font=ImageFont.truetype(F_CN, 12), fill=(120, 128, 140))
    sd.text((400, y + 340), "方案A", font=ImageFont.truetype(F_CN, 12), fill=(120, 128, 140))
    y += 380

sheet.save(os.path.join(OUT, "_plug_compare2.png"))
print("OK")
