#!/usr/bin/env python3
"""flow.py [--macro] [run-tag] - harden tt_um_pettit_lisa locally with LibreLane's
Classic flow on config_merged.json (configure.py; config_merged_macro.json
with --macro).  With --macro the RAM32
DFFRAM macro is in the design and one extra step runs the tile's vertical
power stripes across its pin columns after the PDN is generated (the
single-layer tile PDN does not reach a macro's pins by itself).  Both flows
can pin the registers to a reference placement (ANCHOR_SEQ_TABLE, a
seq_placement.py table; Project.AnchorSequential before global placement,
Project.ReleaseAnchors after it).

    python3 flow.py [--macro] [--to=Step.Id] [tag]   inside the LibreLane nix shell, PDK_ROOT set
                                           (--to=Yosys.Synthesis: synthesis only, `make synth`)
"""
import json
import os
import sys
from typing import List, Optional

from librelane.common import Path
from librelane.config import Variable
from librelane.flows.classic import Classic
from librelane.state import DesignFormat
from librelane.steps import Magic, Odb, OpenROAD, Step
from librelane.steps.odb import OdbpyStep

HERE = os.path.dirname(os.path.abspath(__file__))


class ExtendPowerStripes(OdbpyStep):
    id = "Tile.ExtendPowerStripes"
    name = "Extend Power Stripes Over Macros"

    def get_script_path(self):
        return os.path.join(HERE, "odb_stripes.py")


class AnchorSequential(OdbpyStep):
    """Pins the flops and latches where an earlier run had them (a
    seq_placement.py table keyed by RTL name, odb_anchor_seq.py) right before
    global placement, after the rows are cut and the taps and the PDN are in:
    a good run's register skeleton is reused and the placer arranges the
    logic around it (the placement is not deterministic run to run, and a
    run near the routability threshold is a lottery otherwise).  Registers
    the table does not know place freely.  With ANCHOR_CELLS_TABLE (an
    odb_anchor_cells.py --dump of the reference) the combinational cells are
    pinned too, matched by structure.  No table: nothing happens."""
    id = "Project.AnchorSequential"
    name = "Anchor the Registers to a Reference Placement"
    config_vars = [
        Variable("ANCHOR_SEQ_TABLE", Optional[Path], "seq_placement.py JSON of the run whose register placement is reused; unset = nothing pinned.", default=None),
        Variable("ANCHOR_SEQ_STATUS", str, "Placement status of the pinned registers: FIRM (DEF FIXED, the placers leave them) or PLACED (a starting point only).", default="FIRM"),
        Variable("ANCHOR_CELLS_TABLE", Optional[Path], "odb_anchor_cells.py --dump graph of the run whose placement is reused: the registers by name AND the combinational cells by structure; takes precedence over ANCHOR_SEQ_TABLE.", default=None),
        Variable("ANCHOR_CELLS_ROUNDS", int, "Neighbourhood radius (hops) of the structural matching's local pass.", default=3),
    ]

    def anchoring(self):
        return self.config["ANCHOR_SEQ_TABLE"] is not None or self.config["ANCHOR_CELLS_TABLE"] is not None

    def get_script_path(self):
        if self.config["ANCHOR_CELLS_TABLE"] is not None:
            return os.path.join(HERE, "odb_anchor_cells.py")
        return os.path.join(HERE, "odb_anchor_seq.py")

    def get_command(self) -> List[str]:
        if self.config["ANCHOR_CELLS_TABLE"] is not None:
            return super().get_command() + [
                "--table", str(self.config["ANCHOR_CELLS_TABLE"]),
                "--status", self.config["ANCHOR_SEQ_STATUS"],
                "--rounds", str(self.config["ANCHOR_CELLS_ROUNDS"]),
                "--report", os.path.join(self.step_dir, "anchor_pairs.json"),
            ]
        return super().get_command() + ["--table", str(self.config["ANCHOR_SEQ_TABLE"]), "--status", self.config["ANCHOR_SEQ_STATUS"]]

    def run(self, state_in, **kwargs):
        if not self.anchoring():
            return {}, {}
        return super().run(state_in, **kwargs)


class ReleaseAnchors(OdbpyStep):
    """Sets the registers Project.AnchorSequential pinned back to PLACED right
    after global placement (odb_anchor_release.py): FIRM only has to steer
    the global placer, and left on it breaks the resizers' in-place
    upsizing."""
    id = "Project.ReleaseAnchors"
    name = "Release the Anchored Registers"
    config_vars = AnchorSequential.config_vars

    def get_script_path(self):
        return os.path.join(HERE, "odb_anchor_release.py")

    def run(self, state_in, **kwargs):
        if not AnchorSequential.anchoring(self):
            return {}, {}
        return super().run(state_in, **kwargs)


def merge_art(gds_in, gds_out, info):
    """The art cell (chip_art.py) placed at its die origin in a copy of a
    GDS view.  Returns the number of met4 polygons added."""
    import klayout.db as kdb
    ly = kdb.Layout()
    ly.read(str(gds_in))
    # a run resumed from this step starts from a view that already carries
    # the art: take the old cell out first, or KLayout makes a second one
    for c in [c for c in ly.each_cell() if c.name == info["cell"] or c.name.startswith(info["cell"] + "$")]:
        ly.prune_cell(c.cell_index(), -1)
    top = ly.top_cell()                    # before the art cell exists (a second top until it is placed)
    art = kdb.Layout()
    art.read(str(info["gds"]))
    src = art.cell(info["cell"])
    if src is None:
        raise ValueError(f"cell {info['cell']} not in {info['gds']}")
    dst = ly.create_cell(info["cell"])
    dst.copy_tree(src)
    ox, oy = (int(round(v / ly.dbu)) for v in info["origin"])
    top.insert(kdb.CellInstArray(dst.cell_index(), kdb.Trans(kdb.Vector(ox, oy))))
    ly.write(str(gds_out))
    return dst.shapes(ly.layer(71, 20)).size()


def patch_lef(lef_in, lef_out, design, box):
    """The art's box added to the tile LEF as a met4 obstruction, so the
    top-level router stays off it."""
    import re
    lines = open(lef_in).read().split("\n")
    rect = f"      LAYER met4 ;\n        RECT {box[0]:.3f} {box[1]:.3f} {box[2]:.3f} {box[3]:.3f} ;"
    obs = next((i for i, l in enumerate(lines) if re.match(r"^\s*OBS\s*$", l)), None)
    if obs is not None:
        end = next(i for i in range(obs + 1, len(lines)) if re.match(r"^\s*END\s*$", lines[i]))
        lines[end:end] = rect.split("\n")
    else:
        end = next(i for i, l in enumerate(lines) if re.match(rf"^END\s+{re.escape(design)}\s*$", l))
        lines[end:end] = ["  OBS"] + rect.split("\n") + ["  END"]
    with open(lef_out, "w") as f:
        f.write("\n".join(lines))


@Step.factory.register()
class ChipArt(Step):
    """Merges a met4-only art cell (chip_art.py: a bitmap on a 0.6 um pixel
    grid that meets sky130's met4 rules by construction) into every GDS view
    after stream-out and adds its box to the tile LEF as a met4 obstruction,
    so the Tiny Tapeout top-level router stays off it.  After Magic.WriteLEF
    and before Magic.DRC, which therefore checks the art in place.  The art
    exists only in the GDS: not in the ODB, DEF or netlist (nothing for LVS
    to see - Magic extracts floating metal as nodes without devices, which
    ext2spice never writes), and the tile's own router was kept off the box
    with a ROUTING_OBSTRUCTIONS entry (art.json's "routing_obstruction").
    From ihp-um-janestreet-prism's Project.ChipArt (2026-10-18)."""
    id = "Project.ChipArt"
    name = "Chip Art into the GDS and the LEF"
    inputs = [DesignFormat.GDS, DesignFormat.LEF]
    outputs = [DesignFormat.GDS, DesignFormat.KLAYOUT_GDS, DesignFormat.MAG_GDS, DesignFormat.LEF]
    config_vars = [
        Variable("CHIP_ART_JSON", Optional[Path], "chip_art.py's art.json: the art GDS, its cell, its die origin and box; unset = no art.", default=None),
        Variable("CHIP_ART_CUT_ROWS", bool, "Project.ArtKeepout cuts the standard-cell rows under the art's box (no cells, filler, decap or met1 rails there); pair it with ROUTING_OBSTRUCTIONS on met1-met4 over the box.", default=False),
        Variable("CHIP_ART_KEEPOUT_BOX", Optional[List[float]], "The box the rows are cut under, when it is not the art's own: e.g. run to the rows' end when the art stops a few sites short of it, since pdngen cannot strap a row stub (PDN-0179).", default=None),
    ]

    def run(self, state_in, **kwargs):
        if self.config["CHIP_ART_JSON"] is None:
            return {}, {}
        info = json.load(open(self.config["CHIP_ART_JSON"]))
        design = self.config["DESIGN_NAME"]
        views = {}
        done = []
        for fmt in (DesignFormat.GDS, DesignFormat.KLAYOUT_GDS, DesignFormat.MAG_GDS):
            src = state_in.get(fmt.id)          # State.get takes the format's id, not the DesignFormat
            if src is None:
                continue
            out = os.path.join(self.step_dir, f"{design}.{fmt.extension}")
            n = merge_art(src, out, info)
            views[fmt] = Path(out)
            done.append(f"{fmt.extension}: {n} polygons")
        lef = state_in.get(DesignFormat.LEF.id)
        if lef is not None:
            out = os.path.join(self.step_dir, f"{design}.lef")
            patch_lef(lef, out, design, info["box"])
            views[DesignFormat.LEF] = Path(out)
            done.append("lef: met4 OBS added")
        with open(os.path.join(self.step_dir, "chip_art.log"), "w") as f:
            f.write(f"{info['cell']} at {info['origin']}, box {info['box']}: {'; '.join(done)}\n")
        return views, {}


@Step.factory.register()
class ArtKeepout(OdbpyStep):
    """Cuts the standard-cell rows under the chip art's box (CHIP_ART_JSON,
    with CHIP_ART_CUT_ROWS) right after OpenROAD.CutRows and before the PDN:
    nothing is placed there, ever (the filler and decap included), and no
    met1 rails are drawn there, so the met4 picture lies on bare oxide (Ken:
    that is what makes it visible).  From prism's Project.ArtKeepout."""
    id = "Project.ArtKeepout"
    name = "Chip Art Keep-out (cut rows)"
    config_vars = ChipArt.config_vars

    def get_script_path(self):
        return os.path.join(HERE, "odb_art_keepout.py")

    def get_command(self) -> List[str]:
        box = self.config["CHIP_ART_KEEPOUT_BOX"] or json.load(open(self.config["CHIP_ART_JSON"]))["box"]
        return super().get_command() + ["--box"] + [str(v) for v in box]

    def run(self, state_in, **kwargs):
        if self.config["CHIP_ART_JSON"] is None or not self.config["CHIP_ART_CUT_ROWS"]:
            return {}, {}
        return super().run(state_in, **kwargs)


@Step.factory.register()
class ArtPixels(OdbpyStep):
    """Chip art as placement blockages (Ken's experiment, 2026-10-23): the
    blocked pixels of CHIP_ART_PIXELS_JSON (odb_art_pixels.py), each two
    rows tall and as wide, as hard placement blockages after the rows are
    cut and before the taps and placement - no cell of any kind on them,
    the routing free above them."""
    id = "Project.ArtPixels"
    name = "Chip Art as Placement Blockages"
    config_vars = [
        Variable("CHIP_ART_PIXELS_JSON", Optional[Path], "pixels.json (w, h, rows bottom-up, 1 = blocked); unset = none.", default=None),
        Variable("CHIP_ART_PIXELS_ORIGIN", Optional[List[float]], "The picture's lower-left in um (snapped to the row and site grid).", default=None),
        Variable("CHIP_ART_PIXEL_SITES", int, "A pixel's width in sites.", default=12),
        Variable("CHIP_ART_PIXEL_ROWS", int, "A pixel's height in rows.", default=2),
    ]

    def get_script_path(self):
        return os.path.join(HERE, "odb_art_pixels.py")

    def get_command(self) -> List[str]:
        return super().get_command() + [
            "--pixels", str(self.config["CHIP_ART_PIXELS_JSON"]),
            "--origin"] + [str(v) for v in self.config["CHIP_ART_PIXELS_ORIGIN"]] + [
            "--sites", str(self.config["CHIP_ART_PIXEL_SITES"]),
            "--rows", str(self.config["CHIP_ART_PIXEL_ROWS"])]

    def run(self, state_in, **kwargs):
        if self.config["CHIP_ART_PIXELS_JSON"] is None:
            return {}, {}
        return super().run(state_in, **kwargs)


@Step.factory.register()
class ArtPixelTaps(OdbpyStep):
    """After OpenROAD.TapEndcapInsertion, which does not look at placement
    blockages: the rows Project.ArtPixels's picture crosses re-tapped - the
    taps on pixels removed, and taps added until every free segment of such
    a row has one within 7 um of every point (odb_art_pixels.py
    --move-taps): the pixels cut the rows' n-well into islands, and Magic's
    nwell.4 / LU.2 / LU.3 want a tap in each, within 15 um."""
    id = "Project.ArtPixelTaps"
    name = "Re-tap the Chip Art Pixels' rows"
    config_vars = ArtPixels.config_vars

    def get_script_path(self):
        return os.path.join(HERE, "odb_art_pixels.py")

    def get_command(self) -> List[str]:
        return super().get_command() + ["--move-taps"]

    def run(self, state_in, **kwargs):
        if self.config["CHIP_ART_PIXELS_JSON"] is None:
            return {}, {}
        return super().run(state_in, **kwargs)


def with_anchors(steps):
    steps = list(steps)
    steps.insert(steps.index(Odb.AddRoutingObstructions) + 1, AnchorSequential)
    steps.insert(steps.index(OpenROAD.GlobalPlacement) + 1, ReleaseAnchors)
    steps.insert(steps.index(Magic.WriteLEF) + 1, ChipArt)
    steps.insert(steps.index(OpenROAD.CutRows) + 1, ArtKeepout)
    steps.insert(steps.index(ArtKeepout) + 1, ArtPixels)
    steps.insert(steps.index(OpenROAD.TapEndcapInsertion) + 1, ArtPixelTaps)
    return steps


class StandardFlow(Classic):
    Steps = with_anchors(Classic.Steps)


class MacroFlow(Classic):
    Steps = with_anchors(Classic.Steps)
    Steps.insert(Steps.index(OpenROAD.GeneratePDN) + 1, ExtendPowerStripes)


def main():
    macro = "--macro" in sys.argv
    to = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--to=")), None)
    frm = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--from=")), None)   # resume an existing run (its tag) from this step
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    merged = "config_merged_macro.json" if macro else "config_merged.json"
    cfg = json.load(open(os.path.join(HERE, merged), encoding="utf8"))
    cfg["PDK"] = "sky130A"
    flow_class = MacroFlow if macro else StandardFlow
    flow = flow_class(cfg, design_dir=HERE, pdk_root=os.environ["PDK_ROOT"])
    flow.start(tag=args[0] if args else None, **({"to": to} if to else {}), **({"frm": frm} if frm else {}))


if __name__ == "__main__":
    main()
