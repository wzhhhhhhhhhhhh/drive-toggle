"""每盘图标生成器（最终版）

设计：方案A
  * 硬盘本体：抹掉指示灯圆点（避免和插头徽标粘连）
  * 右上角：盘符角标（状态色圆底 + 白字）
  * 右下角：插头徽标（取反色，表示点击后的状态）
  * 盘色 = 当前状态（绿=已挂载 / 灰=已卸载）

分尺寸策略：
  >= 64px : 盘符 + 插头
  32~48px : 盘符 + 插头（盘符略放大，照顾开始菜单）
  24px    : 只留盘符
  <= 20px : 只留盘体

输出：icons/disk-<A-Z>-on.ico / disk-<A-Z>-off.ico
总开关用的 toggle-on/off.ico 不受影响。
"""
import os
import struct
import numpy as np
from PIL import Image, ImageDraw, ImageFont

SRC = r"C:\Apps\Drive-Toggle\icons\_src"
OUTDIR = r"C:\Apps\Drive-Toggle\icons"
PREV = os.path.join(SRC, "perdisk")
os.makedirs(PREV, exist_ok=True)
TMP = os.path.join(OUTDIR, "build")
os.makedirs(TMP, exist_ok=True)

GREEN = (16, 124, 16, 255)
GRAY = (108, 116, 130, 255)
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)
F_BOLD = r"C:\Windows\Fonts\segoeuib.ttf"
SS = 8
SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]

_alpha_cache = {}


def glyph_alpha(size):
    """硬盘 alpha，并填掉内部封闭孔洞（指示灯圆点）"""
    if size in _alpha_cache:
        return _alpha_cache[size]
    im = Image.open(os.path.join(SRC, "hard-drive.png")).convert("RGBA").resize((size, size), Image.LANCZOS)
    a = np.array(im.split()[3], dtype=np.uint8)
    shape = a > 20
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
    holes = (~shape) & (~outside)
    a2 = a.copy()
    a2[holes] = 255
    _alpha_cache[size] = a2
    return a2


def drive_img(color, size):
    img = Image.new("RGBA", (size, size), color)
    img.putalpha(Image.fromarray(glyph_alpha(size), mode="L"))
    return img


def tint(name, color, size):
    im = Image.open(os.path.join(SRC, name)).convert("RGBA").resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", im.size, color)
    out.putalpha(im.split()[3])
    return out


def draw_letter(img, text, color, cx, cy, px):
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(F_BOLD, max(6, px))
    box = d.textbbox((0, 0), text, font=f)
    d.text((cx - (box[2] - box[0]) / 2 - box[0], cy - (box[3] - box[1]) / 2 - box[1]),
           text, font=f, fill=color)


def disc(img, cx, cy, d, fill):
    dr = ImageDraw.Draw(img)
    gap = int(d * 0.12)
    dr.ellipse([cx - d // 2 - gap, cy - d // 2 - gap, cx + d // 2 + gap, cy + d // 2 + gap], fill=CLEAR)
    dr.ellipse([cx - d // 2, cy - d // 2, cx + d // 2, cy + d // 2], fill=fill)


def render(state, letter, px):
    S = px * SS
    c = GREEN if state == "on" else GRAY
    nxt = GRAY if state == "on" else GREEN
    plug = "plug-disconnected.png" if state == "on" else "plug-connected.png"

    if px >= 32:
        drive_s, letter_d, plug_d, letter_pos, plug_on = 0.76, 0.34, 0.30, (0.76, 0.24), True
    elif px >= 24:
        drive_s, letter_d, plug_d, letter_pos, plug_on = 0.90, 0.44, 0.0, (0.78, 0.22), False
    else:
        drive_s, letter_d, plug_d, letter_pos, plug_on = 0.96, 0.0, 0.0, (0, 0), False

    img = Image.new("RGBA", (S, S), CLEAR)
    n = int(S * drive_s)
    ox = int((S - n) / 2 - (S * 0.04 if px >= 32 else 0))
    oy = int((S - n) / 2 - (S * 0.04 if px >= 32 else 0))
    img.alpha_composite(drive_img(c, n), (ox, oy))

    if letter_d > 0:
        ld = int(S * letter_d)
        lx, ly = int(S * letter_pos[0]), int(S * letter_pos[1])
        disc(img, lx, ly, ld, c)
        draw_letter(img, letter, WHITE, lx, ly + S * 0.004, int(ld * 0.80))

    if plug_on and plug_d > 0:
        pd = int(S * plug_d)
        px_, py_ = int(S * 0.76), int(S * 0.76)
        disc(img, px_, py_, pd, nxt)
        pn = int(pd * 0.62)
        img.alpha_composite(tint(plug, WHITE, pn), (px_ - pn // 2, py_ - pn // 2))

    return img.resize((px, px), Image.LANCZOS)


def write_ico(path, frames):
    frames = sorted(frames, key=lambda x: x[0])
    n = len(frames)
    header = struct.pack("<HHH", 0, 1, n)
    entries = b""
    blobs = b""
    offset = 6 + 16 * n
    for size, im in frames:
        p = os.path.join(TMP, "__pd.png")
        im.save(p, format="PNG")
        data = open(p, "rb").read()
        os.remove(p)
        w = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", w, w, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)
    with open(path, "wb") as f:
        f.write(header + entries + blobs)


letters = [chr(x) for x in range(ord("A"), ord("Z") + 1)]
count = 0
for letter in letters:
    for state in ("on", "off"):
        write_ico(os.path.join(OUTDIR, f"disk-{letter}-{state}.ico"),
                  [(s, render(state, letter, s)) for s in SIZES])
        count += 1
print(f"生成 {count} 个 ico")

# 预览
CHECK = ["D", "E", "F"]
W, H = 980, 620
sheet = Image.new("RGB", (W, H), (250, 251, 252))
sd = ImageDraw.Draw(sheet)
F_CNB = ImageFont.truetype(r"C:\Windows\Fonts\msyhbd.ttc", 18)
F_CN = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 13)
sd.text((20, 12), "每盘图标（方案A · 已抹掉指示灯圆点）", font=F_CNB, fill=(28, 34, 44))

for i, letter in enumerate(CHECK):
    x = 30 + i * 310
    for j, state in enumerate(("on", "off")):
        big = render(state, letter, 256).resize((140, 140), Image.LANCZOS)
        sheet.paste(big, (x + j * 150, 60), big)

sd.text((20, 236), "实际大小 1:1：48 / 32 / 24　　上排=已挂载　下排=已卸载", font=F_CN, fill=(140, 148, 160))
y = 266
for state in ("on", "off"):
    for i, letter in enumerate(CHECK):
        x = 30 + i * 310
        xx = x
        for size in (48, 32, 24):
            im = render(state, letter, size)
            sheet.paste(im, (xx, y), im)
            xx += size + 14
    y += 80

sd.text((20, 440), "24px 只保留盘符，16/20px 只保留盘体（字母必然糊）", font=F_CN, fill=(120, 128, 140))
sheet.save(os.path.join(PREV, "_final_icons.png"))
print("预览已生成")
