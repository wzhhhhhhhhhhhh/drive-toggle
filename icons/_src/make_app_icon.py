"""生成应用图标：透明底 + 纯绿色硬盘字形（无角标）。

用法：python icons/_src/make_app_icon.py
输出：icons/app.ico（同时用于 初始化.exe 和所有窗口的任务栏图标）
"""
import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # icons\
SRC = os.path.join(ROOT, "_src", "hard-drive.png")
OUT = os.path.join(ROOT, "app.ico")

SIZE = 512
GREEN = (16, 155, 94, 255)      # #109B5E —— 与「已挂载」状态色一致
CANVAS_FIT = 0.92               # 字形占画布比例（留边，避免 16px 下贴边被切）


def main():
    glyph = Image.open(SRC).convert("RGBA")
    alpha = glyph.getchannel("A")

    # 裁掉四周透明边，再等比放进画布中央
    bbox = alpha.getbbox()
    if bbox:
        glyph = glyph.crop(bbox)
        alpha = alpha.crop(bbox)

    target = int(SIZE * CANVAS_FIT)
    w, h = glyph.size
    scale = min(target / w, target / h)
    nw, nh = max(1, int(w * scale)), max(1, int(h * scale))
    alpha = alpha.resize((nw, nh), Image.LANCZOS)

    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    solid = Image.new("RGBA", (nw, nh), GREEN)
    canvas.paste(solid, ((SIZE - nw) // 2, (SIZE - nh) // 2), alpha)

    canvas.save(OUT, format="ICO", sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
                                          (64, 64), (128, 128), (256, 256)])
    print("written:", OUT, "glyph", nw, "x", nh)


if __name__ == "__main__":
    main()
