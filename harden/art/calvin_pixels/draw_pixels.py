# The placement picture from check_pixels.py's boxes: cells grey, the
# macro blue, the pixel blockages red.  python3 draw_pixels.py <out.png>
import json, sys
from PIL import Image, ImageDraw
b = json.load(open(sys.argv[1] + ".json"))
s = 2.0
W, H = int(b["die"][0] * s), int(b["die"][1] * s)
im = Image.new("RGB", (W, H), "white")
d = ImageDraw.Draw(im)
def r(x0, y0, x1, y1, c):
    d.rectangle([x0 * s, H - y1 * s, x1 * s, H - y0 * s], fill=c)
for x0, y0, x1, y1, macro in b["cells"]:
    r(x0, y0, x1, y1, (90, 120, 200) if macro else (160, 160, 160))
for x0, y0, x1, y1 in b["blockages"]:
    r(x0, y0, x1, y1, (220, 40, 40))
im.save(sys.argv[1])
print("picture", sys.argv[1])
