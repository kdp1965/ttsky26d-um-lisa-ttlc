# Release the anchors: the standard cells Project.AnchorSequential pinned
# to a reference placement (marked with an "anchored" property; not every
# FIRM cell - the chip-art taps are FIRM and stay) go back to PLACED, right
# after global placement.  FIRM only has to steer the global
# placer; left on, the resizers still swap a pinned cell's master in place
# (repair_design upsizes on the spot) and the detailed placer may not move
# the wider cell off its neighbour (DPL-0033, seen on prism).  Released, the
# cells sit where they are and legalize like any other.  Macros (blocks)
# stay as they are.  From ihp-um-janestreet-prism/odb_anchor_release.py.
import click
import odb
from reader import click_odb


@click.command()
@click_odb
def main(reader):
    block = reader.block
    n = 0
    skipped = 0
    for inst in block.getInsts():
        if inst.getMaster().isBlock():
            continue
        if inst.getPlacementStatus() != "FIRM":
            continue
        # only what the anchor steps pinned (their "anchored" property): the
        # chip-art taps (Project.ArtPixelTaps) are FIRM too and must stay put -
        # released, the legalizer moved 2576 of 5640 and Magic found 96 LU.3 /
        # nwell.4 errors, LVS an n-well mismatch (t6x4-20, 2026-11-20)
        if odb.dbBoolProperty.find(inst, "anchored") is None:
            skipped += 1
            continue
        inst.setPlacementStatus("PLACED")
        n += 1
    print(f"{n} anchored cells released to PLACED; {skipped} other FIRM cells (taps) left as they are")


if __name__ == "__main__":
    main()
