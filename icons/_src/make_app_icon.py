"""生成 初始化.exe 的应用图标：深色圆角底 + 白色硬盘字形 + 蓝色指示灯。

用法：python icons/_src/make_app_icon.py
输出：icons/app.ico
"""
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # icons\
SRC = os.path.join(ROOT, "_src", "hard-drive.png")
OUT = os.path.join(ROOT, "app.ico")

SIZE = 512
INK = (23, 28, 38, 255)          # #171C26 深墨
GLYPH = (255, 255, 255, 255)     # 硬盘字形：白
ACCENT = (79, 110, 247, 255)     # #4F6EF7 指示灯


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def main():
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    plate = Image.new("RGBA", (SIZE, SIZE), INK)
    canvas.paste(plate, (0, 0), rounded_mask(SIZE, int(SIZE * 0.22)))

    # 复用已有的硬盘字形（纯黑 + alpha），换成白色后居中
    glyph = Image.open(SRC).convert("RGBA")
    alpha = glyph.getchannel("A")
    target = int(SIZE * 0.52)
    glyph = glyph.resize((target, target), Image.LANCZOS)
    alpha = alpha.resize((target, target), Image.LANCZOS)
    white = Image.new("RGBA", (target, target), GLYPH)
    pos = ((SIZE - target) // 2, (SIZE - target) // 2)
    canvas.paste(white, pos, alpha)

    # 右下角指示灯
    d = ImageDraw.Draw(canvas)
    r = int(SIZE * 0.030)
    cx, cy = int(SIZE * 0.635), int(SIZE * 0.615)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=ACCENT)

    canvas.save(OUT, format="ICO", sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
                                          (64, 64), (128, 128), (256, 256)])
    print("written:", OUT)


if __name__ == "__main__":
    main()
