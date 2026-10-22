# Harden tt_um_pettit_lisa on this machine with LibreLane (the GitHub runners take
# an hour for what the Mac does in minutes).
#
#   make            # the standard Tiny Tapeout flow: the RAM synthesized from src/RAM32.v
#   make macro      # with the RAM32 DFFRAM macro (macro.json, the stripe step of flow.py)
#   make synth      # synthesis only (runs/synth-<tag>/*-yosys-synthesis/reports): area, cell types
#   chip_art.py     # the met4 picture (art/calvin): see its header and macro.json's "//art"
#   make clean
#
# LibreLane and the tools come from the dev shell of a LibreLane checkout
# (LIBRELANE), the PDK from PDK_ROOT (ciel enable --pdk-family sky130 <the
# open_pdks commit librelane/open_pdks_rev names>).  Run outside the shell,
# each recipe re-runs itself inside it.  Results: runs/<tag>/final/.
LIBRELANE ?= $(HOME)/projects/tiny_tapeout/librelane
export PDK_ROOT ?= $(HOME)/projects/fossi
TAG ?= $(shell date +%Y%m%d-%H%M%S)
# TO=Step.Id stops after that step: TO=OpenROAD.GlobalRouting shows the
# congestion report before the hours of detailed routing.
TO ?=
FLOW_TO = $(if $(TO),--to=$(TO),)
# TILES=8x2 tries another tile (harden/tt_block_8x2_pg.def, macro_8x2.json)
TILES ?=
CONF_TILES = $(if $(TILES),--tiles=$(TILES),)
# OVERLAY=trial.json: a JSON of variables merged last (a per-run trial)
OVERLAY ?=
CONF_TILES += $(if $(OVERLAY),--overlay=$(OVERLAY),)

ifeq ($(IN_NIX_SHELL),)
NIX_RUN = nix-shell $(LIBRELANE)/shell.nix --run
else
NIX_RUN = sh -c
endif

standard:
	$(NIX_RUN) "python3 configure.py $(CONF_TILES) && python3 flow.py $(FLOW_TO) standard-$(TAG)"

macro:
	$(NIX_RUN) "python3 configure.py --macro $(CONF_TILES) && python3 flow.py --macro $(FLOW_TO) macro-$(TAG)"

synth:
	$(NIX_RUN) "python3 configure.py && python3 flow.py --to=Yosys.Synthesis synth-$(TAG)"

# Where is the run (the newest under runs/, or RUN=runs/<tag>): the steps
# done and their durations, the current step's log tail, and once the
# detailed router runs its iterations and the newest DRC report (by layer,
# type, densest bins, nets).  harden-stop kills a router that will not
# converge; the flow fails there and the report on disk is the one to read.
RUN ?=
status:
	python3 status.py $(RUN)

harden-stop:
	python3 status.py $(RUN) --stop

shell:
	nix-shell $(LIBRELANE)/shell.nix

clean:
	rm -rf runs config_merged.json config_merged_macro.json

.PHONY: standard macro status harden-stop shell clean
