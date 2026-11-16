# Icarus unit testbenches of the peripheral blocks on their own (no cocotb):
# each prints PASS / FAIL per check and ALL PASSED or SOME FAILED.
#    make hsc          the high-speed / quadrature counter (src/lisa_hsc.v)
#    make hsc VCD=1    with a waveform (tb_hsc.vcd)
#    make mul16        the 16 x 16 multiplier (src/lisa_mul16.v)
#    make uart2        UART2 (src/lisa_uart.v with its tx8n / rx8n / brg /
#                      autobaud): the transmit FIFO, RS-485 DE, the idle
#                      timer and the receive path (RESPIN 40)
#    make plc          the PLC timers / counters (src/lisa_plc.v)
#    make lint         verilator --lint-only -Wall on the blocks
SRC    = ../../src
IVFLAGS = -g2012
PLUSARGS = $(if $(VCD),+VCD,)

UART2_SRCS = $(SRC)/lisa_uart.v $(SRC)/lisa_tx8n.v $(SRC)/lisa_rx8n.v $(SRC)/debug_brg.v $(SRC)/debug_autobaud.v

all: hsc mul16 uart2 plc

hsc: hsc.vvp
	vvp hsc.vvp $(PLUSARGS)

hsc.vvp: tb_hsc.v $(SRC)/lisa_hsc.v
	iverilog $(IVFLAGS) -o hsc.vvp tb_hsc.v $(SRC)/lisa_hsc.v

mul16: mul16.vvp
	vvp mul16.vvp $(PLUSARGS)

mul16.vvp: tb_mul16.v $(SRC)/lisa_mul16.v
	iverilog $(IVFLAGS) -o mul16.vvp tb_mul16.v $(SRC)/lisa_mul16.v

uart2: uart2.vvp
	vvp -N uart2.vvp $(PLUSARGS)

uart2.vvp: tb_uart2.v $(UART2_SRCS)
	iverilog $(IVFLAGS) -Wall -Wno-timescale -s tb_uart2 -o uart2.vvp tb_uart2.v $(UART2_SRCS)

plc: plc.vvp
	vvp plc.vvp $(PLUSARGS)

plc.vvp: tb_plc.v $(SRC)/lisa_plc.v
	iverilog $(IVFLAGS) -o plc.vvp tb_plc.v $(SRC)/lisa_plc.v

lint:
	verilator --lint-only -Wall $(SRC)/lisa_hsc.v
	verilator --lint-only -Wall $(SRC)/lisa_mul16.v
	verilator --lint-only -Wall $(UART2_SRCS)
	verilator --lint-only -Wall $(SRC)/lisa_plc.v

clean:
	rm -f *.vvp *.vcd

.PHONY: all hsc mul16 uart2 plc lint clean
