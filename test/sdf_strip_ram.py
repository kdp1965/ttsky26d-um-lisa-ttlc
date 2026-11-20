#!/usr/bin/env python3
"""Copy an SDF without the cells inside the RAM32 macro (instances ram1.*),
for a gate-level simulation that uses the behavioural RAM32.v in the macro's
place (its latches cannot be preloaded; RAM32.v starts at zero).
    sdf_strip_ram.py in.sdf out.sdf"""
import sys, re
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
out, i, kept, dropped = [], 0, 0, 0
head_end = text.index(" (CELL\n")
out.append(text[:head_end])
pos = head_end
while True:
    j = text.find("\n (CELL\n", pos)
    cell = text[pos:j] if j >= 0 else text[pos:]
    m = re.search(r"\(INSTANCE\s+([^)\s]*)", cell)
    inst = m.group(1) if m else ""
    if inst.startswith("ram1"):
        dropped += 1
    else:
        out.append(cell); kept += 1
    if j < 0: break
    pos = j + 1
open(dst, "w").write("".join(out) if "".join(out).rstrip().endswith(")") else "".join(out) + ")\n")
print(f"{kept} cells kept, {dropped} ram1 cells dropped -> {dst}")
