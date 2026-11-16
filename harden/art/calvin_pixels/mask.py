# Calvin's pixel mask (chip_art.py's grid: art/calvin/tt_um_pettit_calvin.gds,
# met4 71/20 on 0.6 um pixels) to mask.json: rows bottom-up, 1 = metal (ink).
import json, sys
import klayout.db as kdb
ly = kdb.Layout(); ly.read(sys.argv[1])
reg = kdb.Region(ly.top_cell().begin_shapes_rec(ly.layer(71, 20))); reg.merge()
px = int(round(0.6 / ly.dbu))
bb = reg.bbox()
w = (bb.width() + px - 1) // px; h = (bb.height() + px - 1) // px
rows = []
for y in range(h):
    r = []
    for x in range(w):
        c = kdb.Region(kdb.Box(bb.left + x * px, bb.bottom + y * px, bb.left + (x + 1) * px, bb.bottom + (y + 1) * px))
        r.append(1 if (reg & c).area() * 2 >= px * px else 0)
    rows.append(r)
json.dump({"w": w, "h": h, "rows": rows}, open(sys.argv[2], "w"))
ink = sum(map(sum, rows))
print(f"{w} x {h} px, {ink} ink ({100.0 * ink / (w * h):.1f}%)")
for r in reversed(rows):
    print("".join("#" if v else "." for v in r))
