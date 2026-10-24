# Chip art as placement: a bitmap of pixels (art/calvin_pixels/pixels.json,
# 1 = blocked, rows bottom-up) made into hard placement blockages, each
# pixel ROWS standard-cell rows tall and SITES sites wide, the picture's
# lower-left at ORIGIN (snapped to the row and site grid).  No cell of any
# kind - logic, tap, filler, decap - is placed on a blocked pixel; the rows,
# their met1 rails and the routing go on over them.  A horizontal run of
# blocked pixels is one blockage.  Runs after OpenROAD.CutRows, before the
# taps and the placement (Ken, 2026-10-23: "let's see how badly that throws
# off the route").
#
# --move-taps (a second step, after OpenROAD.TapEndcapInsertion, which does
# not look at placement blockages): the rows the picture crosses re-tapped -
# the taps on pixels removed, then taps added so that every free segment of
# such a row has one within 7 um of every point (Magic's nwell.4 and LU.2 /
# LU.3: the pixels cut the rows' n-well into islands).
import json
import click
import odb
from reader import click_odb


def overlaps(a, b):
    return a[0] < b[2] and a[2] > b[0] and a[1] < b[3] and a[3] > b[1]


def move_taps(block, reach=7.0):
    """Re-tap the rows the picture crosses.  The pixels cut each row's n-well
    into islands, and an island with no tap - or a cell more than 15 um from
    one - fails Magic's nwell.4 / LU.2 / LU.3 (a tap merely slid off a
    pixel can leave its island bare).  So: the taps on pixels are removed,
    each row the picture crosses is split into its free segments, and taps
    are added until every segment has one and no point of it is more than
    REACH um (7, half the 15 um rule) from a tap.  Tapcell's own taps count
    where they already cover."""
    u = block.getDbUnitsPerMicron()
    R = int(round(reach * u))
    blk = [(b.getBBox().xMin(), b.getBBox().yMin(), b.getBBox().xMax(), b.getBBox().yMax()) for b in block.getBlockages()]
    taps = [i for i in block.getInsts() if i.getName().startswith("TAP_")]
    master = taps[0].getMaster()
    tw = master.getWidth()
    removed = 0
    for inst in taps:
        bb = inst.getBBox()
        if any(overlaps((bb.xMin(), bb.yMin(), bb.xMax(), bb.yMax()), b) for b in blk):
            odb.dbInst_destroy(inst)
            removed += 1
    fixed = []                                  # every placed instance: taps, endcaps, the macro
    for inst in block.getInsts():
        if inst.isPlaced():
            bb = inst.getBBox()
            fixed.append((bb.xMin(), bb.yMin(), bb.xMax(), bb.yMax(), inst.getName().startswith("TAP_")))
    added = 0
    for row in block.getRows():
        rb = row.getBBox()
        rbox = (rb.xMin(), rb.yMin(), rb.xMax(), rb.yMax())
        cuts = sorted((b[0], b[2]) for b in blk if b[1] < rb.yMax() and b[3] > rb.yMin())
        if not cuts:
            continue                            # a row the picture does not cross: tapcell's taps stand
        sw = row.getSite().getWidth()
        ox = row.getOrigin()[0]
        segs, x = [], rb.xMin()
        for c0, c1 in cuts:
            if c0 > x:
                segs.append((x, min(c0, rb.xMax())))
            x = max(x, c1)
        if x < rb.xMax():
            segs.append((x, rb.xMax()))
        here = [f for f in fixed if f[1] == rb.yMin()]
        for s0, s1 in segs:
            if s1 - s0 < tw:
                continue
            tapx = sorted(((f[0] + f[2]) // 2) for f in here if f[4] and f[0] >= s0 and f[2] <= s1)
            pos = s0                            # everything left of pos is covered
            while pos < s1:
                if tapx and tapx[0] - R <= pos:
                    pos = max(pos, tapx.pop(0) + R)
                    continue
                # a new tap whose reach starts at pos: its centre at pos + R, on a site, inside the segment
                cx = min(pos + R, s1 - tw // 2)
                x0 = ox + ((cx - tw // 2 - ox) // sw) * sw
                x0 = max(x0, s0 + ((ox - s0) % sw))
                placed = None
                for k in range(0, 200):         # nearest free site, leftwards first: never past pos's reach
                    for cand in (x0 - k * sw, x0 + k * sw):
                        box = (cand, rb.yMin(), cand + tw, rb.yMax())
                        if cand < s0 or cand + tw > s1:
                            continue
                        if any(overlaps(box, f[:4]) for f in here):
                            continue
                        placed = cand
                        break
                    if placed is not None:
                        break
                if placed is None:
                    raise SystemExit(f"art pixels: no room for a tap in row {row.getName()} at {pos / u:.2f}")
                inst = odb.dbInst_create(block, master, f"TAP_ARTPIX_{added}")
                inst.setOrient(row.getOrient())
                inst.setLocation(placed, rb.yMin())
                inst.setPlacementStatus("FIRM")
                box = (placed, rb.yMin(), placed + tw, rb.yMax(), True)
                here.append(box)
                fixed.append(box)
                added += 1
                c = placed + tw // 2
                if c - R > pos:                 # it could not reach back to pos: a gap would stay
                    raise SystemExit(f"art pixels: a tap gap in row {row.getName()} at {pos / u:.2f}")
                pos = c + R
    print(f"art pixels: {removed} taps on the pixels removed, {added} taps added so every row segment "
          f"has one within {reach} um of every point")


@click.command()
@click.option("--move-taps", is_flag=True, help="only move the taps and endcaps off the blockages already there")
@click.option("--pixels", help="pixels.json: w, h, rows (bottom-up, 1 = blocked)")
@click.option("--origin", nargs=2, type=float, help="the picture's lower-left, um")
@click.option("--sites", type=int, default=12, help="a pixel's width in sites")
@click.option("--rows", "nrows", type=int, default=2, help="a pixel's height in rows")
@click_odb
def main(reader, move_taps, pixels, origin, sites, nrows):
    block = reader.block
    if move_taps:
        globals()["move_taps"](block)
        return
    u = block.getDbUnitsPerMicron()
    rows = list(block.getRows())
    site = rows[0].getSite()
    sw, sh = site.getWidth(), site.getHeight()
    rx = min(r.getOrigin()[0] for r in rows)
    ry = min(r.getOrigin()[1] for r in rows)
    ox = rx + round((origin[0] * u - rx) / sw) * sw
    oy = ry + round((origin[1] * u - ry) / sh) * sh
    pw, ph = sites * sw, nrows * sh
    p = json.load(open(pixels))
    n = px = 0
    for y, r in enumerate(p["rows"]):
        x = 0
        while x < p["w"]:
            if not r[x]:
                x += 1
                continue
            x0 = x
            while x < p["w"] and r[x]:
                x += 1
            b = odb.dbBlockage_create(block, ox + x0 * pw, oy + y * ph, ox + x * pw, oy + (y + 1) * ph)
            n += 1
            px += x - x0
    print(f"art pixels: {px} pixels of {pw / u:.2f} x {ph / u:.2f} um as {n} placement blockages, "
          f"the picture {p['w'] * pw / u:.2f} x {p['h'] * ph / u:.2f} um at ({ox / u:.2f}, {oy / u:.2f})")


if __name__ == "__main__":
    main()
