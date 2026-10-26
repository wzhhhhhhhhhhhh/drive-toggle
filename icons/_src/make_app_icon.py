"""生成应用图标：透明底 + 纯绿色硬盘（无角标）。

字形直接用 icons/_src/hard-drive.png——与桌面「硬盘开关 - X 盘」图标同一套造型，
不再自己画几何形状（之前画出来的像个打印机）。

用法：python icons/_src/make_app_icon.py
输出：icons/app.ico（同时用于 初始化.exe 和所有窗口的任务栏图标）
"""
import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # icons\
SRC = os.path.join(ROOT, "_src", "hard-drive.png")
OUT = os.path.join(ROOT, "app.ico")

GREEN = (16, 155, 94, 255)      # #109B5E，与「已挂载」状态色一致
FILL = 0.92                     # 字形占画布比例：硬盘字形偏扁，留白少一点才不显小
SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]


def master():
    """源字形裁到内容边缘，返回 alpha 母版"""
    glyph = Image.open(SRC).convert("RGBA")
    alpha = glyph.getchannel("A")
    bbox = alpha.getbbox()
    if bbox:
        alpha = alpha.crop(bbox)
    return alpha


def frame(alpha, size):
    """等比缩放到 size 画布中央，留白由 FILL 控制"""
    target = max(1, int(size * FILL))
    w, h = alpha.size
    scale = min(target / w, target / h)
    nw, nh = max(1, round(w * scale)), max(1, round(h * scale))
    a = alpha.resize((nw, nh), Image.LANCZOS)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    solid = Image.new("RGBA", (nw, nh), GREEN)
    canvas.paste(solid, ((size - nw) // 2, (size - nh) // 2), a)
    return canvas


def main():
    alpha = master()
    frames = {s: frame(alpha, s) for s in SIZES}
    base = frames[256]
    base.save(
        OUT,
        format="ICO",
        sizes=[(s, s) for s in SIZES],
        append_images=[frames[s] for s in SIZES if s != 256],
    )
    print("written:", OUT, "sizes:", SIZES)


if __name__ == "__main__":
    main()
