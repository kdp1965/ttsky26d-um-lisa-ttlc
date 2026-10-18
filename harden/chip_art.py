#!/usr/bin/env python3
# Chip art: a bitmap (or a hand-edited art cell) into a met4-only GDS cell on
# a pixel grid, with sky130's met4 rules met by construction, plus the
# routing keep-out and the LEF obstruction that go with it.  From
# ihp-um-janestreet-prism/tools/chip_art.py (sg13g2's Metal4 50/0), here
# for sky130A (met4 71/20): 2026-10-18, Ken's calvin on the LISA tile.
#
#   python3 chip_art.py --image art/calvin/source.gds --image-layer 50 0 \
#       --extent 294.2 460.0 330.2 507.4 --box 296.0 460.0 328.4 507.4 \
#       --slot 15 --out art/calvin
#
# runs inside the LibreLane nix shell (PIL, numpy, klayout.db).  Outputs in
# --out: <cell>.gds (met4 71/20; the cell's origin is the box's lower-left
# in die coordinates, so the cell is placed at the box), <cell>.lef (a
# MACRO with the box as a met4 OBS, for the record), art.json (what the
# Project.ChipArt flow step needs: the GDS, the cell, the box as the LEF
# obstruction and the ROUTING_OBSTRUCTIONS entry) and preview.png.
#
# The rules, from sky130A_mr.drc, and how the grid meets them: m4.1 width
# 0.30 and m4.2 spacing 0.30 (every width and gap is a multiple of the
# --pixel 0.6; a checkerboard clean-up removes corner-only contacts), m4.4a
# area 0.24 um2 and m4.7 hole area 0.2 um2 (a pixel is 0.36), m4.5ab 0.4
# between metal 3 um wide and anything (a gap is 0.6), and m4.11, no metal
# that is still there after a 5 um shrink, i.e. no solid area wider than
# 10 um in both directions: --slot N leaves every Nth pixel row of the
# plate empty (15: solid runs of 8.4 um).  The tool re-checks all of them
# on the merged shapes and refuses to write a cell that fails.  Magic's
# met4.5a (what the Tiny Tapeout precheck runs) also fails where thin
# metal leaves a convex corner of a 3 um body on both sides - the two
# pieces of the 0.4 um band around the body meet at the corner point only -
# so the pixel diagonal to such a corner is filled (corners()).  sky130 has
# no fill-exclusion markers; the chip-level fill will sit in the dark
# areas as it does everywhere.
import argparse
import json
import math
import os

import numpy as np
from PIL import Image
import klayout.db as kdb

LAYER_MET4 = (71, 20)


def load_mask_gds(path, w_px, h_px, pixel, layer):
    """A hand-edited art cell onto the pixel grid: the given layer of the
    GDS's top cell, in cell coordinates (0, 0 = the extent's lower-left), a
    pixel being metal when at least half of it is covered.  Row 0 is the
    bottom."""
    ly = kdb.Layout()
    ly.read(path)
    reg = kdb.Region(ly.top_cell().begin_shapes_rec(ly.layer(*layer)))
    reg.merge()
    px = int(round(pixel / ly.dbu))
    mask = np.zeros((h_px, w_px), bool)
    for y in range(h_px):
        for x in range(w_px):
            cell = kdb.Region(kdb.Box(x * px, y * px, (x + 1) * px, (y + 1) * px))
            mask[y, x] = (reg & cell).area() * 2 >= px * px
    return mask, (w_px / 2.0, h_px / 2.0, 0.0)


def load_mask(path, w_px, h_px, mode, threshold, disc):
    """The metal mask (h_px x w_px bools) from the image: light inside the
    avatar's disc is metal (plate), or dark is (ink)."""
    im = Image.open(path).convert("L")
    W, H = im.size
    g = np.asarray(im).astype(float)
    light = g > 200
    ys, xs = np.where(light)
    cx, cy = (xs.min() + xs.max()) / 2.0, (ys.min() + ys.max()) / 2.0
    r = max(xs.max() - xs.min(), ys.max() - ys.min()) / 2.0
    yy, xx = np.mgrid[0:H, 0:W]
    inside = (xx - cx) ** 2 + (yy - cy) ** 2 <= (r + 0.5) ** 2
    g2 = np.where(inside, g, 0.0)
    small = np.asarray(Image.fromarray(g2.astype(np.uint8)).resize((w_px, h_px), Image.LANCZOS)).astype(float)
    sx, sy = w_px / W, h_px / H
    gy, gx = np.mgrid[0:h_px, 0:w_px]
    inside_s = ((gx + 0.5) / sx - cx) ** 2 + ((gy + 0.5) / sy - cy) ** 2 <= (r + 0.5) ** 2 if disc else np.ones((h_px, w_px), bool)
    if mode == "plate":
        mask = (small >= threshold) & inside_s
    else:
        mask = (small < threshold) & inside_s
    return mask, (cx * sx, cy * sy, r * (sx + sy) / 2)


def clean(mask):
    """No two metal pixels touching only at a corner (spacing 0 to a DRC
    checker): fill the 2x2 checkerboards until none is left."""
    m = mask.copy()
    for _ in range(20):
        a, b, c, d = m[:-1, :-1], m[:-1, 1:], m[1:, :-1], m[1:, 1:]
        chk = (a & d & ~b & ~c) | (b & c & ~a & ~d)
        if not chk.any():
            break
        ys, xs = np.where(chk)
        for y, x in zip(ys, xs):
            m[y:y + 2, x:x + 2] = True
    return m


def large_pixels(mask, px):
    """the pixels of the metal that is 3 um wide (Magic's "large" met4: what
    survives a 1.5 um shrink and grow), as a mask"""
    reg = kdb.Region()
    h, w = mask.shape
    for y in range(h):
        for x in range(w):
            if mask[y, x]:
                reg.insert(kdb.Box(x * px, y * px, (x + 1) * px, (y + 1) * px))
    reg.merge()
    large = reg.sized(-1500).sized(1500) & reg
    out = np.zeros_like(mask)
    for y in range(h):
        for x in range(w):
            if mask[y, x]:
                cell = kdb.Region(kdb.Box(x * px, y * px, (x + 1) * px, (y + 1) * px))
                out[y, x] = (large & cell).area() * 2 >= px * px
    return out


def corners(mask, px):
    """Magic's met4.5a (sky130A.tech: a 0.4 um spacing within the band of
    metal 0.4 um around large metal, touching_ok) fails where thin metal
    leaves a convex corner of a large body on both of its sides: the two
    band pieces meet at the corner point only, which Magic counts as zero
    spacing (KLayout's m4.5ab does not see it).  Fill the empty pixel
    diagonal to such a corner.  Returns the number filled."""
    m = mask
    filled = 0
    for _ in range(8):
        large = large_pixels(m, px)
        thin = m & ~large
        h, w = m.shape
        n = 0
        for y in range(h):
            for x in range(w):
                if m[y, x]:
                    continue
                for dx, dy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
                    xx, yy = x + dx, y + dy
                    if 0 <= xx < w and 0 <= yy < h and large[yy, xx] and thin[y, xx] and thin[yy, x]:
                        m[y, x] = True
                        n += 1
                        break
        filled += n
        if n == 0:
            break
        m = clean(m)
    return filled


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True, help="the bitmap; or a .gds of a hand-edited art cell (its metal is re-gridded, see load_mask_gds)")
    ap.add_argument("--image-layer", nargs=2, type=int, default=list(LAYER_MET4), metavar=("LAYER", "DATATYPE"), help="the layer to read from a .gds image (71 20; prism's Metal4 is 50 0)")
    ap.add_argument("--box", nargs=4, type=float, required=True, metavar=("X0", "Y0", "X1", "Y1"), help="the drawn window, die coordinates, um")
    ap.add_argument("--extent", nargs=4, type=float, default=None, metavar=("X0", "Y0", "X1", "Y1"), help="where the whole image goes (default: the box); a larger extent is clipped to the box, e.g. a disc wider than the channel between two PDN pairs")
    ap.add_argument("--pixel", type=float, default=0.6, help="pixel size, um")
    ap.add_argument("--exclude", nargs=4, type=float, action="append", default=[], metavar=("X0", "Y0", "X1", "Y1"), help="met4 to stay clear of (die um); repeatable")
    ap.add_argument("--clearance", type=float, default=1.0, help="grown around every exclusion, um")
    ap.add_argument("--mode", choices=("plate", "ink"), default="plate")
    ap.add_argument("--threshold", type=float, default=128)
    ap.add_argument("--no-disc", action="store_true", help="do not clip to the avatar's disc")
    ap.add_argument("--slot", type=int, default=15, help="leave every Nth pixel row empty (m4.11: no solid metal wider than 10 um both ways); 0 = none")
    ap.add_argument("--cell", default="tt_um_pettit_calvin")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    x0, y0, x1, y1 = a.box
    ex0, ey0, ex1, ey1 = a.extent or a.box
    we_px, he_px = int(round((ex1 - ex0) / a.pixel)), int(round((ey1 - ey0) / a.pixel))
    if a.image.lower().endswith((".gds", ".gds2", ".oas")):
        full, disc = load_mask_gds(a.image, we_px, he_px, a.pixel, tuple(a.image_layer))   # already in die orientation
    else:
        full, disc = load_mask(a.image, we_px, he_px, a.mode, a.threshold, not a.no_disc)
        full = full[::-1, :]                  # the image's row 0 is the top: die orientation has row 0 at the bottom
    cx0, cy0 = int(round((x0 - ex0) / a.pixel)), int(round((y0 - ey0) / a.pixel))
    cx1, cy1 = int(round((x1 - ex0) / a.pixel)), int(round((y1 - ey0) / a.pixel))
    cx0, cy0, cx1, cy1 = max(cx0, 0), max(cy0, 0), min(cx1, we_px), min(cy1, he_px)
    x0, y0 = ex0 + cx0 * a.pixel, ey0 + cy0 * a.pixel
    mask = full[cy0:cy1, cx0:cx1].copy()
    h_px, w_px = mask.shape
    disc = (disc[0] - cx0, disc[1] - cy0, disc[2])
    for kx0, ky0, kx1, ky1 in a.exclude:
        gx0 = int(math.floor((kx0 - a.clearance - x0) / a.pixel)); gx1 = int(math.ceil((kx1 + a.clearance - x0) / a.pixel))
        gy0 = int(math.floor((ky0 - a.clearance - y0) / a.pixel)); gy1 = int(math.ceil((ky1 + a.clearance - y0) / a.pixel))
        mask[max(gy0, 0):max(gy1, 0), max(gx0, 0):max(gx1, 0)] = False
    if a.slot:
        mask[a.slot - 1::a.slot, :] = False
    mask = clean(mask)
    px = int(round(a.pixel * 1000))
    n_corner = corners(mask, px)
    if n_corner:
        print(f"  {n_corner} pixel(s) filled at convex corners of large metal (Magic met4.5a)")

    os.makedirs(a.out, exist_ok=True)
    ly = kdb.Layout(); ly.dbu = 0.001
    cell = ly.create_cell(a.cell)
    l_m4 = ly.layer(*LAYER_MET4)
    # one rectangle per horizontal run of pixels, never merged polygons: a
    # merged plate has holes, which GDS writes as a boundary with cut lines
    # that the Tiny Tapeout 3D viewer's triangulator throws on
    rects = 0
    for y in range(h_px):
        x = 0
        while x < w_px:
            if mask[y, x]:
                xe = x
                while xe < w_px and mask[y, xe]:
                    xe += 1
                cell.shapes(l_m4).insert(kdb.Box(x * px, y * px, xe * px, (y + 1) * px))
                rects += 1
                x = xe
            else:
                x += 1
    reg = kdb.Region(cell.begin_shapes_rec(l_m4))
    reg.merge()
    gds = os.path.join(a.out, a.cell + ".gds")
    ly.write(gds)

    # the rules the grid is supposed to guarantee, checked on the merged shapes (nm)
    npoly = reg.count()
    area = reg.area() * 1e-6
    # m4.5ab as the deck has it: the outer edges of the metal that is 3 um
    # wide (the parts of the merged shapes that survive a 1.5 um shrink)
    # keep 0.4 from every other metal edge
    huge = (reg.sized(-1500).sized(1500)) & reg
    huge_out = huge.edges() & reg.edges()
    other = reg.edges() - huge_out
    checks = {"m4.1 width 0.30": reg.width_check(300, False, kdb.Region.Euclidian).count(),
              "m4.2 space 0.30": reg.space_check(300, False, kdb.Region.Euclidian).count(),
              "m4.4a area 0.24": reg.with_area(0, 240000, False).count(),
              "m4.7 hole area 0.2": reg.holes().with_area(0, 200000, False).count(),
              "m4.5ab 3um-wide space 0.4": huge_out.space_check(400, False, kdb.Edges.Euclidian).count() + huge_out.separation_check(other, 400, False, kdb.Edges.Euclidian).count(),
              "m4.11 width 10 after slotting": reg.sized(-5000).sized(5000).count()}
    for k, v in checks.items():
        print(f"  self-check {k}: {v} violations")
    if any(checks.values()):
        raise SystemExit("the art violates a met4 rule it was meant to meet by construction")
    lef = os.path.join(a.out, a.cell + ".lef")
    with open(lef, "w") as f:
        f.write("VERSION 5.8 ;\nBUSBITCHARS \"[]\" ;\nDIVIDERCHAR \"/\" ;\n\n")
        f.write(f"MACRO {a.cell}\n  CLASS BLOCK ;\n  ORIGIN 0 0 ;\n  FOREIGN {a.cell} 0 0 ;\n")
        f.write(f"  SIZE {w_px * a.pixel:.3f} BY {h_px * a.pixel:.3f} ;\n  SYMMETRY X Y ;\n")
        f.write(f"  OBS\n      LAYER met4 ;\n        RECT 0 0 {w_px * a.pixel:.3f} {h_px * a.pixel:.3f} ;\n  END\nEND {a.cell}\n\nEND LIBRARY\n")
    bx1, by1 = round(x0 + w_px * a.pixel, 3), round(y0 + h_px * a.pixel, 3)
    info = {
        "gds": os.path.abspath(gds), "cell": a.cell, "lef": os.path.abspath(lef),
        "origin": [round(x0, 3), round(y0, 3)], "box": [round(x0, 3), round(y0, 3), bx1, by1],
        "pixel": a.pixel, "pixels": [w_px, h_px], "metal_pixels": int(mask.sum()),
        "rectangles": rects, "merged_polygons": npoly, "metal_area_um2": round(area, 2),
        "routing_obstruction": ["met4", round(x0, 3), round(y0, 3), bx1, by1],
        "exclusions": a.exclude, "clearance": a.clearance, "mode": a.mode, "slot": a.slot, "extent": [ex0, ey0, ex1, ey1],
        "image": os.path.abspath(a.image),
    }
    with open(os.path.join(a.out, "art.json"), "w") as f:
        json.dump(info, f, indent=2)

    S = 6
    img = np.zeros((h_px * S, w_px * S, 3), np.uint8)
    img[np.kron(mask, np.ones((S, S), bool))] = (235, 235, 235)
    for kx0, ky0, kx1, ky1 in a.exclude:
        gx0 = int(round((kx0 - x0) / a.pixel * S)); gx1 = int(round((kx1 - x0) / a.pixel * S))
        gy0 = int(round((ky0 - y0) / a.pixel * S)); gy1 = int(round((ky1 - y0) / a.pixel * S))
        img[max(gy0, 0):max(gy1, 0), max(gx0, 0):max(gx1, 0)] = (120, 30, 30)
    Image.fromarray(img[::-1, :, :]).save(os.path.join(a.out, "preview.png"))
    print(f"{a.cell}: {w_px} x {h_px} pixels of {a.pixel} um = {w_px * a.pixel:.1f} x {h_px * a.pixel:.1f} um at ({x0:.1f}, {y0:.1f}); "
          f"{int(mask.sum())} metal pixels as {rects} rectangles ({npoly} merged polygons), {area:.0f} um2 of met4")
    print(f"wrote {gds}, {lef}, art.json, preview.png")


if __name__ == "__main__":
    main()
