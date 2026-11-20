# An engineering change by hand before detailed routing: the instances named
# in ECO_MOVES are set to the given lower-left (um), site- and row-aligned,
# the user having checked the spot is free.  For the one frozen violation a
# router leaves after 20 iterations (t6x4-23, 2026-11-20: a met1 spacing
# between the clock root's NDR wire and the pin of a gate butted against the
# clock buffer; shifting the three clock buffers one site left into the free
# site beside them opens it).  Resume the run at this step:
#   python3 flow.py --macro --from=Project.EcoMove macro-<tag>   (the overlay carrying ECO_MOVES)
import json
import click
import odb
from reader import click_odb


@click.command()
@click.option("--moves", required=True, help="JSON list of [instance, x_um, y_um]")
@click_odb
def main(reader, moves):
    block = reader.block
    u = block.getDbUnitsPerMicron()
    for name, x, y in json.loads(moves):
        inst = block.findInst(name)
        if inst is None:
            raise SystemExit(f"ECO_MOVES: no instance {name}")
        ox, oy = inst.getLocation()
        inst.setLocation(int(round(x * u)), int(round(y * u)))
        print(f"{name} ({inst.getMaster().getName()}): ({ox / u:.2f}, {oy / u:.2f}) -> ({x:.2f}, {y:.2f})")


if __name__ == "__main__":
    main()
