"""生成应用图标：透明底 + 纯绿色硬盘（无角标）。

按最终尺寸逐个绘制（不是缩放一张大图），小尺寸下才清晰、视觉上也更"满"。

用法：python icons/_src/make_app_icon.py
输出：icons/app.ico（同时用于 初始化.exe 和所有窗口的任务栏图标）
"""
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # icons\
OUT = os.path.join(ROOT, "app.ico")

GREEN = (16, 155, 94, 255)      # #109B5E，与「已挂载」状态色一致
SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]


def draw(size):
    s = size
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # 「盘盖 + 盘体」直接相接（不留缝），小尺寸下整体更实、看起来更大
    lid_top, lid_bottom = 0.04 * s, 0.40 * s
    body_top, body_bottom = 0.40 * s, 0.96 * s
    left, right = 0.02 * s, 0.98 * s

    lid_inset = 0.10 * s
    d.polygon(
        [
            (left + lid_inset, lid_bottom),
            (left + lid_inset * 1.45, lid_top),
            (right - lid_inset * 1.45, lid_top),
            (right - lid_inset, lid_bottom),
        ],
        fill=GREEN,
    )

    d.rounded_rectangle(
        [left, body_top, right, body_bottom],
        radius=int(0.15 * s),
        fill=GREEN,
    )

    # 细节只在够大的尺寸上加，小尺寸加了会糊
    if s >= 32:
        cut = (0, 0, 0, 0)
        for y in (0.56, 0.67, 0.78):
            d.rounded_rectangle(
                [left + 0.10 * s, y * s, left + 0.44 * s, y * s + max(1, 0.035 * s)],
                radius=max(1, int(0.017 * s)),
                fill=cut,
            )
        r = 0.045 * s
        cx, cy = right - 0.13 * s, 0.67 * s
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=cut)

    return img


def main():
    frames = {s: draw(s) for s in SIZES}
    # 以 256 为基准，其余用已按尺寸绘制好的图替换（PIL 会按 sizes 重采样，
    # 但我们提供的图本身就在对应尺寸上有内容，视觉尺寸一致）
    base = frames[256]
    base.save(OUT, format="ICO", sizes=[(s, s) for s in SIZES],
              append_images=[frames[s] for s in SIZES if s != 256])
    print("written:", OUT, "sizes:", SIZES)


if __name__ == "__main__":
    main()
