# A two-colour bitmap (Ken's art/calvin_small/source.png, 73 x 74) to the
# placement-blockage pixels: black = blocked (the circle and the lines),
# white = open.  Writes pixels.json (rows bottom-up) and prints the picture.
#
# Two blocked pixels that touch only at a corner (a 2 x 2 checkerboard) leave
# the cells of the two open pixels across that corner with n-wells meeting
# at a point: Magic's nwell.1 (width < 0.84 um) at the corner (8 of them in
# runs/macro-calvin-small-5x4, 2026-10-23).  So one of the two open pixels
# is blocked as well - the one with more blocked neighbours, which keeps the
# stroke smooth - until no such corner is left; the pixels filled are listed.
import json, sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("L")
W, H = im.size
p = im.load()
rows = [[1 if p[x, H - 1 - y] < 128 else 0 for x in range(W)] for y in range(H)]


def neighbours(x, y):
    return sum(rows[y + dy][x + dx] for dx in (-1, 0, 1) for dy in (-1, 0, 1)
               if (dx or dy) and 0 <= x + dx < W and 0 <= y + dy < H)


filled = []
changed = True
while changed:
    changed = False
    for y in range(H - 1):
        for x in range(W - 1):
            a, b, c, d = rows[y][x], rows[y][x + 1], rows[y + 1][x], rows[y + 1][x + 1]
            if a and d and not b and not c:
                opts = [(x + 1, y), (x, y + 1)]
            elif b and c and not a and not d:
                opts = [(x, y), (x + 1, y + 1)]
            else:
                continue
            fx, fy = max(opts, key=lambda q: neighbours(*q))
            rows[fy][fx] = 1
            filled.append((fx, H - 1 - fy))
            changed = True
json.dump({"w": W, "h": H, "rows": rows}, open(sys.argv[2], "w"))
print(f"{W} x {H} px: {sum(map(sum, rows))} blocked, {len(filled)} filled at diagonal corners "
      f"(x, row from the top): {filled}")
for r in reversed(rows):
    print("".join("#" if v else "." for v in r))
