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
  net missed.  The build is 50 MHz (`CLK_DIV=20`, the demo board's clock)
  since 2026-10-17 with 0.45 ns of setup slack.  What it took, beyond the
  SDC's groups: the window data as a 3-cycle source (which the SDC has
  too, since the same day), and the BF16 adder's cone into the accumulator
  as a 3-cycle path from everything it takes - 29 LUT levels and 21 ns on
  this fabric, two thirds of it routing, 1.3 ns over at first.  The
  accumulator loads only at the end of the execute state (or the stage
  after), and the adder's inputs are all settled three or more clocks
  before: the latched instruction and the decoded operation flags at the
  end of the fetch state (the operand select and gate), the BF16 registers
  and the accumulator at the end of the previous execute state.  The SDC
  covers the first of these on the chip as its one-hot fetch flop to the
  accumulator; here the state register is binary, so that one is applied
  through the stream's core_i_ready net, the select of the instruction
  mux, whose other sources (a breakpoint's stop) it covers as well.  The
  tightest path now is the divider block's registered operand
  classification through the adder into the accumulator (25 levels).
  40 MHz (`CLK_DIV=25`) closes with 1.5 ns and 125000 baud.

Pins (`lisa_arty.v`, `lisa_arty.xdc`): the three Tiny Tapeout ports are
Pmods in the demo board's order (pins 1-4, 7-10 = bits 0-7): JA `ui_in`
(pulled down, as the RP2040 drives them: baud divisor 0, autobaud on), JB
`uo_out`, JC `uio` (the QSPI Pmod; JB and JC are the high-speed Pmods
without series resistors; uio[4] and uio[6], the debugger's other two rx
candidates, are pulled up), JD unused.  The USB-UART is the debug UART:
its rx and JA pin 4 are ANDed into `ui_in[3]` (both idle high), `uo_out[4]`
drives it and JB pin 7.  The RESET button is the reset, held 65536 clocks
after release and after the MMCM locks.  LEDs: LD4 clock locked, LD5 in
reset, LD6 tx, LD7 rx; LD0 (RGB) is the Ethernet: red a frame received,
green one for us, blue one sent.  SW3 up routes the TTLC's I/O to JA / JB
for a real TTLC Pmod; down (the default) it goes to the chains inside the
FPGA, reached over Ethernet (below).

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

- 156250 baud at 50 MHz (125000 at 40): the autobaud's divisor is the
  measured pulse width over 32, and the generator makes a bit 32 times
  (divisor + 1) clocks, so a bit must be a multiple of 32 clocks: 320 at
  both rates (115200 and 460800 are not usable).  pyserial on Linux sets
  the FTDI to 156250 (it runs 0.26% slow, within the measurement).
- One serial session per run: opening the port resets the design (the
  Arty's JP2 jumper ties the FTDI's DTR to the RESET line), which clears
  the debug registers and halts the core.
- The data cache off (`w1d0007`): with it on, evicted lines go to a PSRAM
  that is not set up (on the chip testbench there is one), so the globals
  read back wrong while the stack, hot in the cache, survives.
- `l` after the resume gives the program the debug UART.
- The QSPI Pmod's uio[7:4] (WP#, HOLD#, the PSRAM selects) are pulled up
  in the XDC; uio[7:4] are undriven until a program sets the mux, and a
  floating HOLD# held the flash.
- `CACHE=1 arty_run.py ...` runs with the data cache on the Pmod's PSRAM A
  (CS1): `psram_mod` (0x1c bit 10, from ttgf-um-lisa) with the uio mux at
  2 (0x1c = 0x4aa), CS1 quad and the flash single SPI (0x17 = 6), 6 dummy
  clocks for the PSRAM (0x18 = 0x6a), the cache on CS1 (0x15 = 6), on with
  the 32K map (0x1d = 0x13).  hello, test_core, test_printf, test_irq and
  the two 32K tests (test_bigframe, test_ptroff) pass that way; with
  psram_mod off test_bigframe prints nothing.


## The TTLC's I/O over Ethernet

The TTLC scans its 48 outputs and 48 inputs through three 74HC595 and
three 74HC165 chains on a Pmod (uo_out[2:0] data, uo_out[5] latch,
uo_out[6] shift clock out; ui_in[6:4] in).  On the Arty the chains are
inside the FPGA (`ttlc_chains_fpga.v`, the chip testbench's model made
synchronous: the scan's shift clock is clk/2 at most, so sampling the pins
every clock sees what the chips see), and their two 48-bit registers are
reached from any host on the LAN through the board's Ethernet PHY
(2026-10-17, Ken's choice over a soft processor: the bridge is ~1000 lines
of plain RTL, no toolchain, and the Mac talks to the board directly):

- `eth_mii_mac.v`: a MAC on the DP83848J's MII (4-bit nibbles at 25 MHz,
  the PHY's own RX_CLK and TX_CLK), received frames into two 2 KB buffers
  used in turn, the frame to send in another, each handed between the
  PHY's clock and the project clock by a four-phase handshake - so all
  the protocol logic runs on the project clock.  FCS checked and appended,
  frames padded to 60 bytes, full duplex only.  A frame that arrives
  while both buffers are held is dropped (the host retries); two buffers
  let frames follow each other by the inter-frame gap, since a parse and
  release take ~2 us.
- `eth_ipstack.v`: one address (192.168.1.200, MAC 02:4c:49:53:41:00,
  parameters of `lisa_arty.v`): answers ARP for it, echoes pings, delivers
  UDP datagrams to port 14500 as a byte stream and sends them from it.  A
  parser walks each received frame a byte a clock (the IP header checksum
  summed on the way) and releases it; a builder writes replies into the
  MAC's buffer, with a pass over the IP header for its checksum first,
  waiting for the transmitter while the parser goes on.  No fragments,
  options or gateway; the UDP checksum is sent as zero and not checked.
- `ttlc_eth_app.v`: the commands.  A datagram is a command byte: `I` with
  six little-endian bytes sets the inputs, `R` reads, `S` subscribes the
  sender to an `E` datagram whenever the outputs change (at most one per
  100 us), `U` ends that.  Every datagram is answered with 20 bytes: type
  (`S`, or `E` for an event), flags (bit 0 subscribed, bit 1 SW3, bits
  7:4 the format's version, 1), microseconds since reset, the outputs,
  the inputs, the events sent.
- `eth_ttlc.v` joins the three; `lisa_arty.v` adds the PHY's 25 MHz
  reference clock (the MMCM's second output through an ODDR), its reset
  (from the MMCM's lock only, 26 ms, so the link survives the RESET
  button and the UART's DTR; no MDIO, the PHY autonegotiates from its
  straps) and LD0.  The XDC constrains the two PHY clocks, marks the three
  clocks asynchronous and gives the MII pins the datasheet's delays.

`test/` is the bridge's own testbench (cocotb on Verilator, `make -C
fpga/arty_a7 test`): the PHY's pins driven with frames built in Python
(ARP, pings of several sizes, UDP commands; the wrong MAC, IP, port and
FCS; back-to-back bursts), the chains scanned by the chip's
`shift_reg_io.v`.  On the board, from andromeda or the Mac:

    ping 192.168.1.200
    ttlc_io.py read                      # or: in <hex48>, watch [quiet s], ping
    arty_ttlc.py ../images/ttlc_loopback.hex   # on andromeda, the serial side

`ttlc_io.py` is the client (a class, `TtlcIo`: `read`, `inputs`,
`subscribe`, `events`, and a command line); `arty_ttlc.py` loads a TTLC
program (readmemh bytes, as the chip testbench's flash image) into the
Pmod's flash at byte 0x10000 through the debug port, starts the TTLC (0x1f
= 0x100, 0x15 = 4, 0x1b = 0x3cff) and runs the loopback check over
Ethernet.  2026-10-17: `test/progs/ttlc/ttlc_loopback.hex` copies all
seven patterns from the inputs to the outputs on the board (the first TTLC
run outside simulation, the 12-bit slot format fetched from the flash),
`watch` shows an event per change with the board's timestamps, ping
answers in 0.1 ms from the wired host, a UDP round trip is 2.5 ms from
the Mac over wifi.  At 50 MHz (2026-10-17, the exceptions above) the
same checks pass, hello and test_core with the cache on included.
