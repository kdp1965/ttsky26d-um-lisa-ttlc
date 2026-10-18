# The Ethernet TTLC I/O bridge (eth_ttlc.v and ttlc_chains_fpga.v) on its
# own, scanned by the chip's shift_reg_io.v: cocotb on Verilator.
#   make            run test_eth.py
#   make clean
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

ifeq ($(SIM),verilator)
# Verilator's own makefile runs python3 (its includer script) with cocotb's
# PYTHONHOME in the environment: run cocotb's sim target with cocotb's
# python as a command-line variable, which reaches every sub-make
PYTHON_BIN := $(shell cocotb-config --python-bin)
test:
	$(MAKE) PYTHON3=$(PYTHON_BIN) sim
.PHONY: test
EXTRA_ARGS += -Wno-fatal -Wno-lint -Wno-style --timing
ifeq ($(shell uname),Darwin)
ifeq ($(shell $(shell cocotb-config --python-bin) -c "import platform; print(platform.machine())"),x86_64)
EXTRA_ARGS += -CFLAGS "-arch x86_64" -LDFLAGS "-arch x86_64"
endif
endif
endif

HERE    = $(PWD)
SRC_DIR = $(PWD)/../../../src
VERILOG_SOURCES = $(addprefix $(HERE)/../,eth_crc32_byte.v eth_mii_mac.v eth_ipstack.v ttlc_eth_app.v eth_ttlc.v ttlc_chains_fpga.v)
VERILOG_SOURCES += $(SRC_DIR)/shift_reg_io.v $(HERE)/../../../test/spiflash.v $(HERE)/tb_eth.v
PLUSARGS += +FIRMWARE=$(HERE)/../../../test/progs/hello.hex
COMPILE_ARGS += -I$(SRC_DIR)
TOPLEVEL = tb_eth
COCOTB_TEST_MODULES = test_eth
MODULE = test_eth

include $(shell cocotb-config --makefiles)/Makefile.sim
.DEFAULT_GOAL := test
