# Where every flop and latch sits in a placed (or routed) design, keyed by
# the register's RTL name - the table Project.AnchorSequential (flow.py,
# odb_anchor_seq.py) pins a later run's registers from.  Adapted from
# ihp-um-janestreet-prism/tools/seq_placement.py (sky130 cell names here).
#
# Usage (the LibreLane nix shell, or its openroad directly):
#   openroad -exit -no_splash -python seq_placement.py <design.odb> <out.json> [<out.txt>]
#   e.g. runs/macro-fix/final/odb/tt_um_pettit_lisa.odb placements/macro-fix_final_seq.json
#
# The RTL name of a register is the name of the net on its data output (Q,
# or Q_N when that is the only output): Yosys keeps a register's name on
# that net through synthesis and flattening, while the instance names
# (_NNNN_) are renumbered every run.  Names that look synthetic (_NNNN_,
# netNNN) are flagged: those registers cannot be matched across runs.
#
# JSON: [{"rtl", "inst", "master", "kind", "x", "y", "orient", "status",
# "named"}, ...] (x, y in um, lower-left of the instance).  The text file is
# the same list, one line each, sorted by RTL name, with a summary on top.

import json
import re
import sys
from collections import Counter

import odb

SEQ_MASTER = re.compile(r"__(dfxtp|dfrtp|dfstp|dfbbn|dfbbp|dfxbp|dfrbp|dfsbp|dfrtn|dlxtp|dlxtn|dlxbp|dlxbn|dlrtp|dlrtn|dlrbp|dlrbn|dlclkp|sdf|sedf|edf)", re.I)
NOT_SEQ = re.compile(r"(dlygate|dlymetal|clkdlybuf)", re.I)    # delay cells from hold repair, not state
LATCH_MASTER = re.compile(r"__(dlxt|dlxb|dlrt|dlrb|dlclk)", re.I)
SYNTHETIC = re.compile(r"^(_\d+_|net\d+|\$.*)$")


def main(odb_path, json_out, text_out=None):
    db = odb.dbDatabase.create()
    odb.read_db(db, odb_path)
    block = db.getChip().getBlock()
    u = block.getDbUnitsPerMicron()

    rows = []
    for inst in block.getInsts():
        master = inst.getMaster()
        if master.isBlock():
            continue
        mname = master.getName()
        if NOT_SEQ.search(mname) or not (master.isSequential() or SEQ_MASTER.search(mname)):
            continue
        outs = {}
        for it in inst.getITerms():
            mt = it.getMTerm()
            if mt.getSigType() != "SIGNAL" or mt.getIoType() != "OUTPUT":
                continue
            net = it.getNet()
            outs[mt.getName()] = net.getName() if net is not None else None
        qname = outs.get("Q") or outs.get("Q_N") or next((v for v in outs.values() if v), None)
        rtl = qname.replace("\\", "") if qname else None
        x, y = inst.getLocation()
        rows.append({
            "rtl": rtl,
            "inst": inst.getName(),
            "master": mname,
            "kind": "latch" if LATCH_MASTER.search(mname) else "flop",
            "x": round(x / u, 3),
            "y": round(y / u, 3),
            "orient": inst.getOrient(),
            "status": inst.getPlacementStatus(),
            "named": bool(rtl) and not SYNTHETIC.match(rtl),
        })

    rows.sort(key=lambda r: (not r["named"], r["rtl"] or "", r["inst"]))
    with open(json_out, "w") as f:
        json.dump(rows, f, indent=1)

    kinds = Counter(r["kind"] for r in rows)
    masters = Counter(r["master"] for r in rows)
    unnamed = [r for r in rows if not r["named"]]
    dup = Counter(r["rtl"] for r in rows if r["named"])
    dups = {k: v for k, v in dup.items() if v > 1}
    summary = [
        f"{len(rows)} sequential cells: {kinds.get('flop', 0)} flops, {kinds.get('latch', 0)} latches",
        f"{len(rows) - len(unnamed)} carry an RTL name on their output net, {len(unnamed)} do not "
        f"(synthetic net name: cannot be matched across runs)",
        f"{len(dups)} RTL names are shared by more than one cell" + (f": {sorted(dups.items())[:5]} ..." if dups else ""),
        "cells by master: " + ", ".join(f"{m} {n}" for m, n in masters.most_common()),
    ]
    for line in summary:
        print(line)

    if text_out:
        with open(text_out, "w") as f:
            for line in summary:
                f.write("# " + line + "\n")
            f.write("# rtl_name  kind  master  x_um  y_um  orient  status  instance\n")
            for r in rows:
                f.write(f"{r['rtl'] or '-'}  {r['kind']}  {r['master']}  {r['x']:.3f}  {r['y']:.3f}  {r['orient']}  {r['status']}  {r['inst']}\n")
        print(f"wrote {json_out} and {text_out}")
    else:
        print(f"wrote {json_out}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
