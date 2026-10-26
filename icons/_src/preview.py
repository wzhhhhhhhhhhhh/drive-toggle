"""从 ico 里取各尺寸，拼最终预览图。"""
import io
import os
import struct
from PIL import Image

D = r"C:\Apps\Drive-Toggle\icons"


def frames(path):
    data = open(path, "rb").read()
    count = struct.unpack("<H", data[4:6])[0]
    out = {}
    for i in range(count):
        off = 6 + i * 16
        w, h, _, _, _, _, size, img_off = struct.unpack("<BBBBHHII", data[off:off + 16])
        w = 256 if w == 0 else w
        out[w] = Image.open(io.BytesIO(data[img_off:img_off + size])).convert("RGBA")
    return out


m = frames(os.path.join(D, "mount-v4.ico"))
u = frames(os.path.join(D, "unmount-v4.ico"))

sheet = Image.new("RGB", (900, 460), (252, 252, 253))
for i, src in enumerate((m, u)):
    base_x = 40 + i * 450
    big = src[256]
    sheet.paste(big, (base_x, 20), big)

    x = base_x
    for size in (16, 24, 32, 48):
        scale = 3 if size <= 24 else 2
        small = src[size].resize((size * scale, size * scale), Image.NEAREST)
        sheet.paste(small, (x, 330 + (96 - size * scale) // 2), small)
        x += size * scale + 14

sheet.save(os.path.join(D, "_src", "preview.png"))
print("OK")
