# After a run: the cells on the blocked pixels (there should be none) and a
# picture of the placement - every cell a grey box, the blockages red.
#   openroad -python check_pixels.py <odb> <out.png>
# (OpenROAD's Python has no PIL: the boxes go to <out>.json and
# draw_pixels.py, run with the shell's python3, makes the picture)
import json
import sys
import odb

db = odb.dbDatabase.create()
odb.read_db(db, sys.argv[1])
block = db.getChip().getBlock()
u = block.getDbUnitsPerMicron()
blk = [b.getBBox() for b in block.getBlockages()]
print(f"{len(blk)} placement blockages")
bad = {}
for inst in block.getInsts():
    m = inst.getMaster()
    if m.isBlock():
        continue
    bb = inst.getBBox()
    for b in blk:
        if bb.xMin() < b.xMax() and bb.xMax() > b.xMin() and bb.yMin() < b.yMax() and bb.yMax() > b.yMin():
            bad.setdefault(m.getName(), 0)
            bad[m.getName()] += 1
            break
print("cells on blocked pixels:", sum(bad.values()), dict(sorted(bad.items(), key=lambda kv: -kv[1])[:8]))
die = block.getDieArea()
boxes = {"die": [die.xMax() / u, die.yMax() / u],
         "cells": [[b.xMin() / u, b.yMin() / u, b.xMax() / u, b.yMax() / u, inst.getMaster().isBlock()]
                   for inst in block.getInsts() for b in [inst.getBBox()]],
         "blockages": [[b.xMin() / u, b.yMin() / u, b.xMax() / u, b.yMax() / u] for b in blk]}
json.dump(boxes, open(sys.argv[2] + ".json", "w"))
print("boxes", sys.argv[2] + ".json")
