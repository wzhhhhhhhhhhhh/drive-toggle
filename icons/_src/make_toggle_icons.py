"""生成单按钮「切换」图标：盘色=当前状态，插头徽标色=切换后的状态。

输出：
  icons/toggle-on.ico   （当前已挂载：绿盘 + 灰插头=点击将断开）
  icons/toggle-off.ico  （当前已卸载：灰盘 + 绿插头=点击将接入）
  icons/_src/toggle/_final.png （预览）
"""
import os
WINDIR = os.environ.get('WINDIR', r'C:\Windows')
FONTDIR = os.path.join(WINDIR, 'Fonts')
import struct
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = HERE
OUTDIR = os.path.dirname(HERE)
PREV = os.path.join(SRC, "toggle")
os.makedirs(PREV, exist_ok=True)
TMP = os.path.join(OUTDIR, "build")
os.makedirs(TMP, exist_ok=True)

GREEN = (16, 124, 16, 255)
GRAY = (108, 116, 130, 255)
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)
SS = 8
SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
BADGE_FROM = 32


def tint(name, color, size):
    im = Image.open(os.path.join(SRC, name)).convert("RGBA").resize((size, size), Image.LANCZOS)
    solid = Image.new("RGBA", im.size, color)
    solid.putalpha(im.split()[3])
    return solid


def make(state, px):
    """state: 'on' = 当前已挂载 / 'off' = 当前已卸载"""
    S = px * SS
    cur = GREEN if state == "on" else GRAY     # 当前状态色（盘）
    nxt = GRAY if state == "on" else GREEN     # 切换后的状态色（插头）
    # 已挂载 -> 下一步断开（拔出的插头）；已卸载 -> 下一步接入（插上的插头）
    plug = "plug-disconnected.png" if state == "on" else "plug-connected.png"

    img = Image.new("RGBA", (S, S), CLEAR)
    d = ImageDraw.Draw(img)

    if px < BADGE_FROM:
        n = int(S * 0.90)
        img.alpha_composite(tint("hard-drive.png", cur, n), ((S - n) // 2, (S - n) // 2))
        return img.resize((px, px), Image.LANCZOS)

    n = int(S * 0.70)
    img.alpha_composite(tint("hard-drive.png", cur, n), (int(S * 0.06), int(S * 0.08)))

    bd = int(S * 0.36)
    cx, cy = int(S * 0.70), int(S * 0.70)
    gap = int(bd * 0.13)
    d.ellipse([cx - bd // 2 - gap, cy - bd // 2 - gap,
               cx + bd // 2 + gap, cy + bd // 2 + gap], fill=CLEAR)
    d.ellipse([cx - bd // 2, cy - bd // 2, cx + bd // 2, cy + bd // 2], fill=nxt)
    pn = int(bd * 0.62)
    img.alpha_composite(tint(plug, WHITE, pn), (cx - pn // 2, cy - pn // 2))
    return img.resize((px, px), Image.LANCZOS)


def write_ico(path, frames):
    frames = sorted(frames, key=lambda x: x[0])
    n = len(frames)
    header = struct.pack("<HHH", 0, 1, n)
    entries = b""
    blobs = b""
    offset = 6 + 16 * n
    for size, im in frames:
        p = os.path.join(TMP, f"__t{size}.png")
        im.save(p, format="PNG")
        data = open(p, "rb").read()
        os.remove(p)
        w = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", w, w, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)
    with open(path, "wb") as f:
        f.write(header + entries + blobs)


for state, name in (("on", "toggle-on.ico"), ("off", "toggle-off.ico")):
    write_ico(os.path.join(OUTDIR, name), [(s, make(state, s)) for s in SIZES])
    print("wrote", name)

# ---- 预览 ----
def read_frames(path):
    data = open(path, "rb").read()
    cnt = struct.unpack("<H", data[4:6])[0]
    out = {}
    for i in range(cnt):
        off = 6 + i * 16
        w, h, _, _, _, _, size, io_ = struct.unpack("<BBBBHHII", data[off:off + 16])
        w = 256 if w == 0 else w
        import io
        out[w] = Image.open(io.BytesIO(data[io_:io_ + size])).convert("RGBA")
    return out

on = read_frames(os.path.join(OUTDIR, "toggle-on.ico"))
off = read_frames(os.path.join(OUTDIR, "toggle-off.ico"))

FONT = os.path.join(FONTDIR, 'msyhbd.ttc')
font = ImageFont.truetype(FONT, 17)
small = ImageFont.truetype(FONT, 14)
sheet = Image.new('RGB', (760, 620), (252, 252, 253))
sd = ImageDraw.Draw(sheet)
for i, (label, fr) in enumerate((("已挂载 → 点击将断开", on), ("已卸载 → 点击将接入", off))):
    x = 30 + i * 380
    big = fr[256].resize((180, 180), Image.LANCZOS)
    sheet.paste(big, (x, 30), big)
    sd.text((x, 218), label, font=font, fill=(40, 46, 56))
    cx = x
    for size in (48, 32, 16):
        s = fr[size].resize((size * 2, size * 2), Image.NEAREST)
        sheet.paste(s, (cx, 250), s)
        cx += size * 2 + 14
# 深色底检查
dark = Image.new("RGB", (700, 170), (38, 42, 50))
sheet.paste(dark, (30, 400))
for i, fr in enumerate((on, off)):
    bg = Image.new("RGBA", (150, 150), (38, 42, 50, 255))
    bg.alpha_composite(fr[256].resize((130, 130), Image.LANCZOS), (10, 10))
    sheet.paste(bg.convert("RGB"), (60 + i * 200, 410))
sd.text((60, 570), "深色壁纸下的效果", font=small, fill=(120, 128, 140))

sheet.save(os.path.join(PREV, "_final.png"))
print("OK")
