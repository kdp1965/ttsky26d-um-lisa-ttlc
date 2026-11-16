# The placement-blockage pixels of Calvin (Ken, 2026-10-23): from mask.json
# (chip_art.py's met4 plate, 1 = metal), block the drawing's lines - the
# empty pixels inside the disc - and a one-pixel outline of the disc; the
# corners outside the disc stay open for cells.  Writes pixels.json (rows
# bottom-up, 1 = blocked) and prints the picture.
import json, sys
m = json.load(open(sys.argv[1]))
rows, w, h = m["rows"], m["w"], m["h"]
disc = [[0] * w for _ in range(h)]
for y, r in enumerate(rows):
    if 1 in r:
        a = r.index(1); b = w - 1 - r[::-1].index(1)
        for x in range(a, b + 1):
            disc[y][x] = 1
def inside(x, y):
    return 0 <= x < w and 0 <= y < h and disc[y][x]
px = [[0] * w for _ in range(h)]
for y in range(h):
    for x in range(w):
        if not disc[y][x]:
            continue
        edge = not all(inside(x + dx, y + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
        px[y][x] = 1 if (edge or not rows[y][x]) else 0
json.dump({"w": w, "h": h, "rows": px}, open(sys.argv[2], "w"))
n = sum(map(sum, px))
print(f"{w} x {h} px: {n} blocked ({sum(map(sum, disc))} in the disc)")
for r in reversed(px):
    print("".join("#" if v else "." for v in r))
