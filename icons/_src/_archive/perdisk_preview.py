"""每盘图标的候选设计：把盘符融进硬盘字形。

仅预览，不改动已安装的图标。
"""
import os
from PIL import Image, ImageDraw, ImageFont

SRC = r"C:\Apps\Drive-Toggle\icons\_src"
OUT = os.path.join(SRC, "perdisk")
os.makedirs(OUT, exist_ok=True)

S = 1024
GREEN = (16, 124, 16, 255)
GRAY = (108, 116, 130, 255)
WHITE = (255, 255, 255, 255)
INK = (28, 34, 44, 255)
CLEAR = (0, 0, 0, 0)

FONT_BOLD = r"C:\Windows\Fonts\segoeuib.ttf"
FONT_SEMI = r"C:\Windows\Fonts\segoeuisb.ttf"


def tint(name, color, size):
    im = Image.open(os.path.join(SRC, name)).convert("RGBA").resize((size, size), Image.LANCZOS)
    solid = Image.new("RGBA", im.size, color)
    solid.putalpha(im.split()[3])
    return solid


def draw_letter(img, text, color, cx, cy, px):
    d = ImageDraw.Draw(img)
    try:
        f = ImageFont.truetype(FONT_BOLD, px)
    except Exception:
        f = ImageFont.load_default()
    box = d.textbbox((0, 0), text, font=f)
    w, h = box[2] - box[0], box[3] - box[1]
    d.text((cx - w / 2 - box[0], cy - h / 2 - box[1]), text, font=f, fill=color)
    return box


def base_drive(canvas, color, scale=0.94, dx=0.0, dy=0.0):
    n = int(S * scale)
    x = int((S - n) / 2 + S * dx)
    y = int((S - n) / 2 + S * dy)
    im = tint("hard-drive.png", color, n)
    canvas.alpha_composite(im, (x, y))
    return im, (x, y)


# ---------- 1：盘符直接压在盘面中央 ----------
def design_1(state, letter):
    c = GREEN if state == "on" else GRAY
    img = Image.new("RGBA", (S, S), CLEAR)
    drv, (ox, oy) = base_drive(img, c)
    bb = drv.getbbox()
    cx = ox + (bb[0] + bb[2]) / 2
    cy = oy + bb[1] + (bb[3] - bb[1]) * 0.70
    draw_letter(img, letter, WHITE, cx, cy, int(bb[3] - bb[1]) * 0.36)
    return img


# ---------- 2：盘符压盘面 + 右下角插头徽标（信息最全） ----------
def design_2(state, letter):
    c = GREEN if state == "on" else GRAY
    nxt = GRAY if state == "on" else GREEN
    plug = "plug-disconnected.png" if state == "on" else "plug-connected.png"
    img = Image.new("RGBA", (S, S), CLEAR)
    drv, (ox, oy) = base_drive(img, c, scale=0.80, dx=-0.05, dy=-0.05)
    bb = drv.getbbox()
    cx = ox + (bb[0] + bb[2]) / 2
    cy = oy + bb[1] + (bb[3] - bb[1]) * 0.70
    draw_letter(img, letter, WHITE, cx, cy, int(bb[3] - bb[1]) * 0.40)

    d = ImageDraw.Draw(img)
    bd = int(S * 0.34)
    bx, by = int(S * 0.72), int(S * 0.72)
    gap = int(bd * 0.13)
    d.ellipse([bx - bd // 2 - gap, by - bd // 2 - gap, bx + bd // 2 + gap, by + bd // 2 + gap], fill=CLEAR)
    d.ellipse([bx - bd // 2, by - bd // 2, bx + bd // 2, by + bd // 2], fill=nxt)
    pn = int(bd * 0.62)
    img.alpha_composite(tint(plug, WHITE, pn), (bx - pn // 2, by - pn // 2))
    return img


# ---------- 3：盘符做成右下角角标 ----------
def design_3(state, letter):
    c = GREEN if state == "on" else GRAY
    img = Image.new("RGBA", (S, S), CLEAR)
    base_drive(img, c, scale=0.80, dx=-0.05, dy=-0.05)
    d = ImageDraw.Draw(img)
    bd = int(S * 0.36)
    bx, by = int(S * 0.72), int(S * 0.72)
    gap = int(bd * 0.13)
    d.ellipse([bx - bd // 2 - gap, by - bd // 2 - gap, bx + bd // 2 + gap, by + bd // 2 + gap], fill=CLEAR)
    d.ellipse([bx - bd // 2, by - bd // 2, bx + bd // 2, by + bd // 2], fill=WHITE)
    draw_letter(img, letter, c, bx, by + int(bd * 0.02), int(bd * 0.78))
    return img


# ---------- 4：盘符压在盘面，但加一块深色底板提对比 ----------
def design_4(state, letter):
    c = GREEN if state == "on" else GRAY
    img = Image.new("RGBA", (S, S), CLEAR)
    drv, (ox, oy) = base_drive(img, c)
    bb = drv.getbbox()
    cx = ox + (bb[0] + bb[2]) / 2
    cy = oy + bb[1] + (bb[3] - bb[1]) * 0.70
    d = ImageDraw.Draw(img)
    pw, ph = int(S * 0.30), int(S * 0.30)
    d.rounded_rectangle([cx - pw / 2, cy - ph / 2, cx + pw / 2, cy + ph / 2],
                        radius=int(ph * 0.28), fill=(0, 0, 0, 90))
    draw_letter(img, letter, WHITE, cx, cy, int(ph * 0.82))
    return img


DESIGNS = [
    ("1", "盘符压盘面", "最融合：字母直接写在盘体上", design_1),
    ("2", "盘面字母 + 插头徽标", "信息最全：状态色 + 盘符 + 点击后动作", design_2),
    ("3", "盘符做角标", "盘面干净，字母在右下角圆牌里", design_3),
    ("4", "盘面字母 + 深色底板", "对比更强，但多了一个色块", design_4),
]

LETTER = "D"
made = {}
for key, name, desc, fn in DESIGNS:
    for state in ("on", "off"):
        im = fn(state, LETTER)
        made[(key, state)] = im
        im.resize((256, 256), Image.LANCZOS).save(os.path.join(OUT, f"p{key}_{state}.png"))

# 拼图
LABEL, COL_W, SM = 250, 210, 120
W = LABEL + COL_W * 2 + SM * 2 + 90
H = 100 + (COL_W + 42) * len(DESIGNS) + 10
sheet = Image.new("RGB", (W, H), (250, 251, 252))
sd = ImageDraw.Draw(sheet)
f_t = ImageFont.truetype(r"C:\Windows\Fonts\msyhbd.ttc", 20)
f_s = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 13)

sd.text((16, 14), "每盘图标 · 盘符融入硬盘", font=f_t, fill=INK)
sd.text((LABEL, 56), "已挂载", font=f_s, fill=(110, 120, 135))
sd.text((LABEL + COL_W, 56), "已卸载", font=f_s, fill=(110, 120, 135))
sd.text((LABEL + COL_W * 2 + 22, 56), "48px", font=f_s, fill=(150, 158, 170))
sd.text((LABEL + COL_W * 2 + SM + 22, 56), "32px", font=f_s, fill=(150, 158, 170))

y = 96
for key, name, desc, fn in DESIGNS:
    sd.text((16, y + 66), key + "  " + name, font=f_t, fill=INK)
    sd.text((16, y + 96), desc, font=f_s, fill=(90, 98, 110))
    for i, state in enumerate(("on", "off")):
        big = made[(key, state)].resize((COL_W - 12, COL_W - 12), Image.LANCZOS)
        sheet.paste(big, (LABEL + i * COL_W, y), big)
    for i, size in enumerate((48, 32)):
        x = LABEL + COL_W * 2 + 22 + i * SM
        for j, state in enumerate(("on", "off")):
            s = made[(key, state)].resize((size * 2, size * 2), Image.LANCZOS)
            sheet.paste(s, (x + j * (size * 2 + 10), y + (COL_W - size * 2) // 2), s)
    y += COL_W + 42

sheet.save(os.path.join(OUT, "_sheet.png"))
print("OK", sheet.size)
