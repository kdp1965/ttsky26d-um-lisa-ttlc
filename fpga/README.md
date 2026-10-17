# LISA on an FPGA

`arty_a7/` puts the chip's RTL (`src/`, unchanged) on a Digilent Arty
A7-35T (XC7A35T) with Vivado, so programs and the debugger can be tried on
the respin's logic before the silicon is back, at speed and with the real
QSPI Pmod.

What differs from the chip:

- The 32x32 RAM is `src/RAM32.v`, the RTL model of the DFFRAM macro
  (the standard-flow RAM; Vivado makes it distributed RAM or flops).
- The sky130 cells `debug_regs.v` and `lisa_dbg.v` instantiate: the
  `and2_4` is an AND (`fpga_cells.v`); the `dlrtp_1` latches of the static
  debug registers (base addresses, the output and I/O muxes, breakpoints)
  are flops.  `latch2flop.py` copies the two files to `gen/` with each
  latch an `fpga_dlrtp` clocked by the module's `clk`, which captures the
  value during the debug write strobe, as the latch does.
- The project clock comes from the board's 100 MHz oscillator through an
  MMCM (`lisa_arty_clk.v`): 1000 MHz / `CLK_DIV`, 20 = 50 MHz (the demo
  board SDK's default), 25 = 40, 15 = 66.67 (the TT07 chip's ceiling);
  `make CLK_DIV=25`.
- Timing: `lisa_arty_mcp.tcl`, sourced after synthesis, is `src/lisa.sdc`'s
  multi-cycle exceptions on the Vivado netlist (the same register groups,
  found by their RTL names; the build log prints the counts).  Two of the
  SDC's groups are not ported (its pre-decode flop, one-hot on the chip,
  and its divider-operand group, which its register walk resolved to the IX
  low byte and the accumulator), and the debugger's step and skip levels are
  in the continue group with cont_q_r, which the SDC's walk of the cont_q
  net missed.  The default build is 40 MHz (`CLK_DIV=25`): at 50 MHz the
  longest single-cycle path left, the instruction window's data through
  the decode and the BF16 adder into the accumulator (30 LUT levels), is
  about 21 ns, 1.1 ns over, and the chip's SDC does not relax the window
  data either (only the PC and the window's count and head address) - a
  3-cycle exception on it, like the PC's, is a decision for the chip too.

Pins (`lisa_arty.v`, `lisa_arty.xdc`): the three Tiny Tapeout ports are
Pmods in the demo board's order (pins 1-4, 7-10 = bits 0-7): JA `ui_in`
(pulled down, as the RP2040 drives them: baud divisor 0, autobaud on), JB
`uo_out`, JC `uio` (the QSPI Pmod; JB and JC are the high-speed Pmods
without series resistors; uio[4] and uio[6], the debugger's other two rx
candidates, are pulled up), JD unused.  The USB-UART is the debug UART:
its rx and JA pin 4 are ANDed into `ui_in[3]` (both idle high), `uo_out[4]`
drives it and JB pin 7.  The RESET button is the reset, held 65536 clocks
after release and after the MMCM locks.  LEDs: LD4 clock locked, LD5 in
reset, LD6 tx, LD7 rx.

Build: `make -C fpga/arty_a7` where Vivado is on the PATH, or `make -C
fpga/arty_a7 remote` from a machine without it (copies `src/` and the
directory to the clone on `HOST`, andromeda by default, and runs the build
there; `make remote-prog` programs the board on that machine, `make
remote-log` shows the end of its log).  `build/` has the bitstream,
timing, utilization and DRC reports.  `make lint` runs Verilator over the
whole thing without Vivado.  Running a program (2026-10-17, on andromeda with a Tiny Tapeout QSPI Pmod
on JC): `arty_run.py <file.ihx> [seconds]` loads it into the flash through
the debug port (lisa-tools `lisa_pydb`, which reads Intel HEX since then),
reads back the first words, turns the data cache off, runs it, hands it
the UART and prints what it sends.  hello, test_core, test_printf and
test_irq (rev-2 builds) give lisa_sim --rev2's output.  What it takes:

- 125000 baud: the autobaud measures a bit in 32-clock steps, and 40 MHz /
  125000 is exactly 320 clocks a bit (115200 and 460800 are not usable at
  40 MHz).
- One serial session per run: opening the port resets the design (the
  Arty's JP2 jumper ties the FTDI's DTR to the RESET line), which clears
  the debug registers and halts the core.
- The data cache off (`w1d0007`): with it on, evicted lines go to a PSRAM
  that is not set up (on the chip testbench there is one), so the globals
  read back wrong while the stack, hot in the cache, survives.
- `l` after the resume gives the program the debug UART.
- The QSPI Pmod's uio[7:4] (WP#, HOLD#, the PSRAM selects) are pulled up
  in the XDC; uio[7:4] are undriven until a program sets the mux, and a
  floating HOLD# held the flash.  `psram_mod` (0x1c bit 10, from
  ttgf-um-lisa) maps the data cache's quad SPI onto the Pmod's pins (not
  tried yet).
