# The core-level testbench (tb_core.v): make [IHX=<prog.ihx>] [CACHE=1] [ILAT=1] [TIMEOUT=clocks] [DUMP=1]
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
export COCOTB_RESOLVE_X = ZEROS
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../../src
TB_DIR  = $(PWD)/..

PROJECT_SOURCES  = lisa_core.v lisa_dbg.v lisa_div.v lisa_periph.v lisa_uart.v lisa_rx8n.v lisa_tx8n.v
PROJECT_SOURCES += debug_brg.v debug_autobaud.v lisa_i2c.v lisa_spi.v lisa_ttlcio.v lisa_timer3.v lisa_ws2812.v i2c_master_byte_ctrl.v i2c_master_bit_ctrl.v
PROJECT_SOURCES += data_cache8.v RAM32.v lisa_qqspi.v
PROJECT_SOURCES += fops.v lampFPU_div_top.sv lampFPU_div.sv lampFPU_fractDiv.sv lampFPU_utils.v

SIM_BUILD        = sim_build
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
VERILOG_SOURCES += $(TB_DIR)/test_cells.v $(TB_DIR)/psram.v $(PWD)/tb_core.v
COMPILE_ARGS    += -I$(SRC_DIR)
TOPLEVEL = tb_core
COCOTB_TEST_MODULES = test_core
MODULE = test_core

ifneq ($(IHX),)
FIRMWARE = $(PWD)/$(SIM_BUILD)/$(notdir $(basename $(IHX))).hex
PLUSARGS += +FIRMWARE=$(FIRMWARE) +PROGRAM=$(notdir $(IHX))
CUSTOM_SIM_DEPS += $(FIRMWARE)
$(FIRMWARE): $(IHX) $(TB_DIR)/ihx2hex.py
	mkdir -p $(dir $@)
	$(PYTHON_BIN) $(TB_DIR)/ihx2hex.py $< $@
endif
ifneq ($(CACHE),)
PLUSARGS += +CACHE
endif
ifneq ($(ILAT),)
PLUSARGS += +ILAT=$(ILAT)
endif
ifneq ($(TIMEOUT),)
PLUSARGS += +TIMEOUT=$(TIMEOUT)
endif
ifneq ($(SEND),)
PLUSARGS += +SEND=$(SEND)
endif
ifneq ($(STOP),)
PLUSARGS += +STOP="$(STOP)"
endif
ifneq ($(TRACEWIN),)
PLUSARGS += +TRACEWIN=$(TRACEWIN)
endif
ifneq ($(TRACEPC),)
PLUSARGS += +TRACEPC=$(TRACEPC)
endif
ifneq ($(DUMP),)
PLUSARGS += +DUMP
endif

include $(shell cocotb-config --makefiles)/Makefile.sim

# a run every time (cocotb would otherwise consider an existing results file up to date)
$(COCOTB_RESULTS_FILE): FORCE
FORCE:
.PHONY: FORCE
