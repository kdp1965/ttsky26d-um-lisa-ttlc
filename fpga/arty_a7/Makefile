# LISA on the Digilent Arty A7-35T.
#
# On a machine with Vivado on the PATH (andromeda: source
# ~/xilinx/Vivado/2024.1/settings64.sh first):
#   make            synthesize, place, route, build/lisa_arty.bit (~10 min)
#   make prog       program the Arty on this machine's USB (volatile)
#   make lint       Verilator lint of the wrapper and the design (no Vivado)
#   make test       the Ethernet TTLC I/O bridge's testbench (cocotb, Verilator)
#
# From the Mac (no Vivado here): the targets below copy src/ and this
# directory to the clone on $(HOST) and run make there.
#   make remote     build on $(HOST); the log and reports stay there
#   make remote-prog
#   make remote-log tail of the remote build log
VIVADO     ?= vivado
PART       ?= xc7a35ticsg324-1L
CLK_DIV    ?= 20          # 1000 MHz / CLK_DIV: 20 = 50 MHz (closes since 2026-10-17, see README), 25 = 40, 15 = 66.67
HOST       ?= andromeda
SETTINGS   ?= ~/xilinx/Vivado/2024.1/settings64.sh
REMOTE_DIR ?= projects/tiny-tapeout/ttsky26d/ttsky26d-um-lisa-ttlc

SRC  = ../../src
GEN  = gen/debug_regs.v gen/lisa_dbg.v
CHIP = tt_um_pettit_lisa.v RAM32.v lisa_core.v lisa_div.v lisa_periph.v lisa_io_mux.v \
	   lisa_qqspi.v lisa_qspi_controller.v lisa_rx8n.v lisa_tx8n.v lisa_i2c.v lisa_spi.v lisa_ttlcio.v lisa_timer3.v lisa_ws2812.v lisa_cyccnt.v lisa_wdt.v \
	   debug_ctrl.v debug_autobaud.v debug_brg.v data_cache8.v inst_stream.v \
	   i2c_master_byte_ctrl.v i2c_master_bit_ctrl.v lisa_uart.v \
	   fops.v lampFPU_div_top.sv lampFPU_div.sv lampFPU_fractDiv.sv lampFPU_utils.v \
	   mc14500b.v ttlc_io.v ttlc_fetch.v shift_reg_io.v
ARTY = fpga_cells.v lisa_arty_clk.v eth_crc32_byte.v eth_mii_mac.v eth_ipstack.v ttlc_eth_app.v \
	   eth_ttlc.v ttlc_chains_fpga.v m3_pmod.v lisa_arty.v
LINT_FLAGS ?= -Wno-fatal -Wno-DECLFILENAME -Wno-PROCASSINIT -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
	          -Wno-PINCONNECTEMPTY -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC

all: bit

$(GEN): $(SRC)/debug_regs.v $(SRC)/lisa_dbg.v latch2flop.py
	python3 latch2flop.py $(SRC) gen

bit: $(GEN)
	mkdir -p build
	$(VIVADO) -mode batch -nojournal -log build/vivado.log -source build.tcl -tclargs $(PART) $(CLK_DIV)

prog:
	$(VIVADO) -mode batch -nojournal -nolog -source program.tcl

lint: $(GEN)
	verilator --lint-only -Wall $(LINT_FLAGS) --top-module lisa_arty -I$(SRC) \
	    $(addprefix $(SRC)/,$(CHIP)) $(GEN) $(ARTY)

# the Ethernet TTLC I/O bridge alone, cocotb on Verilator (test/)
test:
	$(MAKE) -C test

remote-sync:
	rsync -a --exclude build --exclude gen --exclude .Xil ../../src/ $(HOST):$(REMOTE_DIR)/src/
	rsync -a --exclude build --exclude gen --exclude .Xil --rsync-path="mkdir -p $(REMOTE_DIR)/fpga/arty_a7 && rsync" ./ $(HOST):$(REMOTE_DIR)/fpga/arty_a7/

remote: remote-sync
	ssh $(HOST) 'source $(SETTINGS) && make -C $(REMOTE_DIR)/fpga/arty_a7 bit PART=$(PART) CLK_DIV=$(CLK_DIV)'

remote-prog:
	ssh $(HOST) 'source $(SETTINGS) && make -C $(REMOTE_DIR)/fpga/arty_a7 prog'

remote-log:
	ssh $(HOST) 'tail -30 $(REMOTE_DIR)/fpga/arty_a7/build/vivado.log'

clean:
	rm -rf gen build .Xil vivado*.jou vivado*.log

.PHONY: all bit prog lint test remote-sync remote remote-prog remote-log clean
