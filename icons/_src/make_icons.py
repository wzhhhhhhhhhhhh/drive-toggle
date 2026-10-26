"""最终图标：透明背景 + 硬盘 + 插头徽标（分尺寸）。

  >= 64px：硬盘 + 右下角插头徽标，徽标周围挖空一圈（透明）与硬盘隔开
  <= 48px：只留硬盘并放大
配色：绿 #107C10 / 红 #C42B1C，无底色。
"""
import os
import struct
from PIL import Image, ImageDraw

SRC = r"C:\Apps\Drive-Toggle\icons\_src"
OUTDIR = r"C:\Apps\Drive-Toggle\icons"
TMP = os.path.join(OUTDIR, "build")
os.makedirs(TMP, exist_ok=True)

GREEN = (16, 124, 16, 255)
RED = (196, 43, 28, 255)
CLEAR = (0, 0, 0, 0)
WHITE = (255, 255, 255, 255)
SS = 8
SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
BADGE_FROM = 32
VER = "v4"


def tint(name, color, size):
    im = Image.open(os.path.join(SRC, name)).convert("RGBA").resize((size, size), Image.LANCZOS)
    solid = Image.new("RGBA", im.size, color)
    solid.putalpha(im.split()[3])
    return solid


def make(kind, px):
    S = px * SS
    accent = GREEN if kind == "mount" else RED
    plug = "plug-connected.png" if kind == "mount" else "plug-disconnected.png"
    img = Image.new("RGBA", (S, S), CLEAR)
    d = ImageDraw.Draw(img)

    if px < BADGE_FROM:
        n = int(S * 0.90)
        img.alpha_composite(tint("hard-drive.png", accent, n), ((S - n) // 2, (S - n) // 2))
        return img.resize((px, px), Image.LANCZOS)

    # 小尺寸把徽标做大一点，否则开始菜单里看不见
    if px <= 48:
        drive_r, badge_r, gap_r, plug_r, cy_r = 0.86, 0.46, 0.09, 0.60, 0.75
    else:
        drive_r, badge_r, gap_r, plug_r, cy_r = 0.92, 0.40, 0.13, 0.62, 0.745

    n = int(S * drive_r)
    img.alpha_composite(tint("hard-drive.png", accent, n), ((S - n) // 2, int(S * 0.40) - n // 2))

    # 徽标：先挖透明环，再画圆底和插头
    bd = int(S * badge_r)
    cx, cy = int(S * cy_r), int(S * cy_r)
    gap = int(bd * gap_r)
    d.ellipse([cx - bd // 2 - gap, cy - bd // 2 - gap,
               cx + bd // 2 + gap, cy + bd // 2 + gap], fill=CLEAR)
    d.ellipse([cx - bd // 2, cy - bd // 2, cx + bd // 2, cy + bd // 2], fill=accent)
    pn = int(bd * plug_r)
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
        p = os.path.join(TMP, f"__{size}.png")
        im.save(p, format="PNG")
        data = open(p, "rb").read()
        os.remove(p)
        w = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", w, w, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)
    with open(path, "wb") as f:
        f.write(header + entries + blobs)


for kind in ("mount", "unmount"):
    write_ico(os.path.join(OUTDIR, f"{kind}-{VER}.ico"), [(s, make(kind, s)) for s in SIZES])
    print("wrote", kind, VER)
