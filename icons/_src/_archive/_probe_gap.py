from PIL import Image
im = Image.open(r"C:\Apps\Drive-Toggle\icons\_src\hard-drive.png").convert("RGBA")
print("size", im.size)
w, h = im.size
a = im.split()[3]
# 扫中间那一列，找 alpha 为 0 的连续区间
col = [a.getpixel((w//2, y)) for y in range(h)]
runs = []
start = None
for y, v in enumerate(col):
    if v < 20 and start is None:
        start = y
    elif v >= 20 and start is not None:
        runs.append((start, y-1, y-start))
        start = None
if start is not None:
    runs.append((start, h-1, h-start))
print("中间列的透明区间（y起, y止, 高度）:")
for r in runs:
    print("  ", r)
print("总高", h)
