# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# defaults
# Verilator when it is installed (cocotb needs 5.036 or later), else icarus:
# make SIM=icarus.  On this Mac cocotb's libraries are x86_64 builds.
SIM ?= $(if $(shell which verilator),verilator,icarus)
ifeq ($(SIM),verilator)
# Verilator's own makefile runs python3 (its includer script) with cocotb's
# PYTHONHOME in the environment: hand it cocotb's python as a command-line
# variable of every sub-make
export MAKEFLAGS += PYTHON3=$(shell cocotb-config --python-bin)
EXTRA_ARGS += -Wno-fatal -Wno-lint -Wno-style --timing
ifeq ($(shell uname),Darwin)
ifeq ($(shell $(shell cocotb-config --python-bin) -c "import platform; print(platform.machine())"),x86_64)
EXTRA_ARGS += -CFLAGS "-arch x86_64" -LDFLAGS "-arch x86_64"
endif
endif
endif
.DEFAULT_GOAL := sim
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src

# The design, as info.yaml lists it (data_cache8.v is the 8-line cache the
# chip has; data_cache.v is the older 4-line one with the same module name,
# so only one of them can be compiled).
PROJECT_SOURCES  = tt_um_pettit_lisa.v RAM32.v
PROJECT_SOURCES += lisa_core.v lisa_dbg.v lisa_div.v lisa_periph.v lisa_io_mux.v
PROJECT_SOURCES += lisa_qqspi.v lisa_qspi_controller.v lisa_rx8n.v lisa_tx8n.v lisa_i2c.v lisa_spi.v lisa_ttlcio.v lisa_timer3.v lisa_ws2812.v lisa_cyccnt.v lisa_wdt.v
PROJECT_SOURCES += debug_ctrl.v debug_autobaud.v debug_brg.v debug_regs.v
PROJECT_SOURCES += data_cache8.v inst_stream.v
PROJECT_SOURCES += i2c_master_byte_ctrl.v i2c_master_bit_ctrl.v lisa_uart.v
PROJECT_SOURCES += fops.v lampFPU_div_top.sv lampFPU_div.sv lampFPU_fractDiv.sv lampFPU_utils.v
PROJECT_SOURCES += mc14500b.v ttlc_io.v ttlc_fetch.v shift_reg_io.v

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD        = sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
# behavioural models of the sky130 cells debug_regs.v instantiates
VERILOG_SOURCES += $(PWD)/test_cells.v

else

# Gate level simulation:
SIM_BUILD        = sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DUSE_POWER_PINS
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v
# a locally hardened build with the RAM32 DFFRAM macro needs its netlist too:
# make GATES=yes MACRO_NETLIST=../macros/RAM32.pnl.v
VERILOG_SOURCES += $(MACRO_NETLIST)

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS    += -I$(SRC_DIR)
# SPI_TCO=<ns>: the flash's and PSRAM's data reach the chip that much later
ifneq ($(SPI_TCO),)
COMPILE_ARGS    += -DSPI_TCO=$(SPI_TCO)
endif
# SPI_DOUT_DLY=<ns>: the flash and PSRAM see the chip's data lines that much after SCLK
ifneq ($(SPI_DOUT_DLY),)
COMPILE_ARGS    += -DSPI_DOUT_DLY=$(SPI_DOUT_DLY)
endif

# The testbench: the DUT with a SPI flash (firmware.hex) on CE0, a SPI RAM on
# CE1 and a UART on the debug port.
VERILOG_SOURCES += $(PWD)/tb.v $(PWD)/spiflash.v $(PWD)/psram.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test
MODULE = test

# make TTLC=1: the TTLC loopback through the testbench's I/O chains
# make BANK=1: the bank registers (progs/bank.c)
# make OVERRUN=1: the UART receive FIFO's overrun flag (progs/uartov.c)
# A program from the SDCC test suite (or any Intel HEX / @addr / opcode-per-line
# image): make IHX=<file> [CACHE=1] [SPI=1] [TIMEOUT=<clocks of silence>] [STATS=1] [DUMP=1]
ifeq ($(IHX),)
ifneq ($(OVERRUN),)
# make OVERRUN=1: the UART receive FIFO's overrun flag (RESPIN 14, progs/uartov.c)
PLUSARGS += +FIRMWARE=$(PWD)/progs/uartov.hex +PROGRAM=uartov.hex +OVERRUN
else ifneq ($(BANK),)
# make BANK=1: the bank registers (RESPIN 22) - progs/bank.c with a routine in
# code banks 1, 2, 3 (progs/bank_test.hex), the data cache on
PLUSARGS += +FIRMWARE=$(PWD)/progs/bank_test.hex +PROGRAM=bank_test.hex +BANK
else ifneq ($(SPIM),)
# the SPI master (RESPIN 29): progs/spi.c against the testbench's two
# devices on the mux-2 pins, then on the TTLC's pins with the TTLC
# running its loopback (progs/spi_test.hex: spi at 0, the loopback at 0x10000)
PLUSARGS += +FIRMWARE=$(PWD)/progs/spi_test.hex +PROGRAM=spi_test.hex +SPIM
else ifneq ($(TTLCIO),)
# the TTLC's I/O from the core (RESPIN 30): progs/ttlcio.c with the ICU
# halted (the chains are the core's), then with the ICU running its
# loopback (progs/ttlcio_test.hex: ttlcio at 0, the loopback at 0x10000)
PLUSARGS += +FIRMWARE=$(PWD)/progs/ttlcio_test.hex +PROGRAM=ttlcio_test.hex +TTLCIO
else ifneq ($(TIMER3),)
# Timer 3 (RESPIN 32): progs/timer3.c - the plain timer, compare, the
# captures of tb.v's square wave, the vector-9 interrupt, PWM on uo[1] / uo[2]
PLUSARGS += +FIRMWARE=$(PWD)/progs/timer3.hex +PROGRAM=timer3.hex +TIMER3
else ifneq ($(WS2812),)
# the WS2812B driver (RESPIN 33): progs/ws2812.c - frames on uo[1] and
# uo[2] decoded by tb.v's ws2812_rx, the vector-6 request, an underrun
PLUSARGS += +FIRMWARE=$(PWD)/progs/ws2812.hex +PROGRAM=ws2812.hex +WS2812
else ifneq ($(MISC36),)
# RESPIN 36: progs/misc36.c - the cycle counter, the watchdog (a reset and
# the restart), the PDM outputs (their duty on uo[1] / uo[2], mux 2)
PLUSARGS += +FIRMWARE=$(PWD)/progs/misc36.hex +PROGRAM=misc36.hex +MISC36
else ifneq ($(DDRSWEEP),)
# RESPIN 37: the DDR capture point swept through the debugger's flash reads,
# then hello in DDR at the middle of the passing points (with SPI_TCO= /
# SPI_DOUT_DLY= for a round trip, DTR_LAUNCH=1 for the flash's first nibble
# an edge later)
PLUSARGS += +FIRMWARE=$(PWD)/progs/hello.hex +PROGRAM=hello.hex +DDRSWEEP
else ifneq ($(I2C),)
# the I2C master in io mux mode 3 (the custom Pmod's CE latch, the cache
# through it): progs/i2c.c against tb.v's slave at 0x3C (an SSD1309's)
PLUSARGS += +FIRMWARE=$(PWD)/progs/i2c.hex +PROGRAM=i2c.hex +I2C
else ifneq ($(WSDMA),)
# the WS2812B driver's DMA (RESPIN 35): progs/wsdma.c - frames from the
# PSRAM through the TTLC's fetch on uo[1] / uo[2], the cache on
PLUSARGS += +FIRMWARE=$(PWD)/progs/wsdma.hex +PROGRAM=wsdma.hex +WSDMA
else ifneq ($(TTLC),)
# TTLC_IMAGE=<hex>: another flash image (the TTLC program at byte 0x10000);
# TTLCTRACE=<clocks> logs the TTLC's fetch (SIM=icarus)
TTLC_IMAGE ?= $(PWD)/progs/ttlc_test.hex
PLUSARGS += +FIRMWARE=$(TTLC_IMAGE) +PROGRAM=$(notdir $(TTLC_IMAGE)) +TTLC
ifneq ($(TTLCTRACE),)
PLUSARGS += +TTLCTRACE=$(TTLCTRACE)
endif
ifneq ($(TTLCIN),)
PLUSARGS += +TTLCIN=$(TTLCIN)
endif
else
PLUSARGS += +FIRMWARE=$(PWD)/progs/hello.hex +PROGRAM=hello.hex +DEFAULT
endif
else
FIRMWARE = $(PWD)/$(SIM_BUILD)/$(notdir $(basename $(IHX))).hex
PLUSARGS += +FIRMWARE=$(FIRMWARE) +PROGRAM=$(notdir $(IHX))
CUSTOM_SIM_DEPS += $(FIRMWARE)
$(FIRMWARE): $(IHX) ihx2hex.py
	mkdir -p $(dir $@)
	$(PYTHON_BIN) ihx2hex.py $< $@
endif
ifneq ($(CACHE),)
PLUSARGS += +CACHE
endif
# M3=1: io mux mode 3 - the CEs latched from uio[0..2] (tb.v's 7475), DQ2 / DQ3 on uio[6] / [7]
ifneq ($(M3),)
PLUSARGS += +M3
endif
ifneq ($(SPI),)
PLUSARGS += +SPI
endif
ifneq ($(DDR_TOGGLE),)
PLUSARGS += +DDR_TOGGLE=$(DDR_TOGGLE)
ifneq ($(DDR_TOGGLE_ONLY),)
PLUSARGS += +DDR_TOGGLE_ONLY=$(DDR_TOGGLE_ONLY)
endif
endif
ifneq ($(DTR_LAUNCH),)
PLUSARGS += +DTR_LAUNCH=$(DTR_LAUNCH)
endif
ifneq ($(TIMEOUT),)
PLUSARGS += +TIMEOUT=$(TIMEOUT)
endif
ifneq ($(STATS),)
PLUSARGS += +STATS           # the fetch counts (clocks per instruction, the wait for the flash)
endif
ifneq ($(SEND),)
PLUSARGS += +SEND='$(SEND)'            # typed to the program (escapes as in Python) ...
ifneq ($(SEND_DELAY),)
PLUSARGS += +SEND_DELAY=$(SEND_DELAY)  # ... this many clocks after the start
endif
ifneq ($(SEND_PROMPT),)
PLUSARGS += +SEND_PROMPT='$(SEND_PROMPT)'  # ... a line at a time, each after this prompt shows
endif
endif
ifneq ($(TRACE),)
PLUSARGS += +TRACE=$(abspath $(TRACE))   # tb.v: an instruction trace (I/D/P/C/X lines)
ifneq ($(TRACE_PC),)
PLUSARGS += +TRACE_PC=$(TRACE_PC)        # start at this window address (hex) ...
endif
ifneq ($(TRACE_CB),)
PLUSARGS += +TRACE_CB=$(TRACE_CB)        # ... in this code bank
endif
ifneq ($(TRACE_COUNT),)
PLUSARGS += +TRACE_COUNT=$(TRACE_COUNT)  # stop after n instructions
endif
ifneq ($(TRACE_FINISH),)
PLUSARGS += +TRACE_FINISH                # and end the simulation there
endif
endif
ifneq ($(DUMP),)
PLUSARGS += +DUMP
# Verilator traces only when built for it: cocotb's VERILATOR_TRACE adds
# --trace and the runtime switch, --trace-fst makes tb.vcd (and dump.fst) FST
VERILATOR_TRACE = 1
COMPILE_ARGS += --trace-fst
endif

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim

# a run every time (cocotb would otherwise consider an existing results file up to date)
$(COCOTB_RESULTS_FILE): FORCE
FORCE:
.PHONY: FORCE
