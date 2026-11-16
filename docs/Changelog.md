# The 6x4 tile (branch tile6x4, 2026-11)

* The tile grows from 5x4 to 6x4 (1030.40 x 511.36 um), the RAM32 moved one
  more stripe pitch to the right (x 699.66).
* PLC timers and counters (peripheral registers 0x50-0x59): six on / off
  delay timers and four up / down counters in the TTLC's I/O space (139-144
  the timers' IN / Q, 147-150 the counters' CU / Q, storage bits 120-123
  their resets; the layout has eight slots of each, the empty ones read 0),
  usable from LISA too.
* The peripheral read decode is two-level (the 16-register group of the
  address selects the block, the block decodes its four low bits): the
  peripheral-read path gained 1.6 ns at the slow corner.
* Two high-speed / quadrature counters (0x60-0x6F) on any pair of ui_in
  pins: pulses, pulses with a direction, x1 or x4 quadrature, a compare with
  MATCH / OVF / UNF and interrupt vector 10, the compare level at TTLC
  addresses 155 / 156.
* A 16 x 16 multiplier peripheral (0x70-0x78): a 32-bit product in four
  clocks, signed or unsigned, with multiply-accumulate.
* UART2 for Modbus RTU: an 8-byte transmit FIFO, an RS-485 direction output
  on uo[7] (mux 2), a frame-idle timer (0x16, 0x17; new bits of 0x13).
* A stack pointer limit fault (0x7A-0x7D): below the limit, an interrupt
  (vector 11) or a reset like the watchdog's.
* The `sleep` instruction (0xA01C): the core waits, fetching nothing, for an
  enabled interrupt source.
* The TTLC's internal storage doubled again to 128 bits (192-255; bytes
  24-31 of LISA's view, TIDX 0-31).
* The interrupt vector table has 11 slots; sdcc emits them.

## What changed since Tiny Tapeout 7

# Revision 2
The TT07 chip was characterized on the demo board with the SDCC port's test
suite, the LISA Commander and lisa_ide; this revision fixes what was found
(the list, with the tests, is `RESPIN.md` in the repository):

* The ALU's carry: `adc`, `sub`, `cmp` and `cpi` use a real carry-in (TT07
  folded it into an 8-bit operand: `adc #0xff` with C set added 0, `sub`
  and `cmp` of a zero operand borrowed); `cpi` records the signed inversion.
  `add` has no carry-in, as designed.
* `ret #imm8` loads A with the immediate.
* The divider keeps its 16-bit result in RA, bit 15 as `ra_cond`, so `xchg
  ra; txau` reads the high byte; it writes nothing to memory. Division by
  one gives the whole dividend.
* `swap a,n(sp)` exchanges with the byte at sp + n.
* The data cache maps the whole 32K (TT07 took bit 14 of a line's address
  from address bit 5, so X and X ^ 0x4000 shared a location), and a
  read-modify-write on a cache miss waits for the line.
* Interrupts are taken only between whole instructions: not after `if`,
  `iftt`, `ifte`, the first word of `ldx`, `lddiv` or a two-word `div`/`rem`,
  nor after `ei`/`di`, `stirq`, `xchg ia`. The shadows take the state the
  interrupted instruction leaves behind, now including `amode`, `cflag_save`
  and the live signed inversion; `rets` restores them all and sets the
  predicate to 11. `ldirq`/`stirq` carry the whole set: bits 7:5 amode, 4
  the live signed inversion, 3 cflag_save, 2 the saved signed inversion, 1
  Z, 0 C. A new `ldamode` (0xA148) reads {ie, amode} into A bits 3:0.
* The bfloat16 adder is correct (three guard bits, round to nearest even,
  or toward zero with amode[2]; subnormals; inf - inf = NaN) and `fmul`'s
  underflow is zero, not infinity (subnormal operands and results flush to
  zero; the product is truncated as before).
* The debugger: a halt no longer takes the data bus while a store is landing
  (a breakpoint right after a store kept the store and RAM[IX]); the step
  bit executes exactly one instruction; a resume runs the instruction at its
  breakpoint; `brk` halts the core; RAM reads with the cache off return the
  addressed byte; register 1 shows `amode` in bits 14:12.
* The console UART has an 8-byte receive FIFO (TT07 held one byte).
* The TTLC's input scan takes 16 samples (TT07: 17, every input one position
  high), its breakpoints halt before their instruction, its step bit runs
  one instruction, and a stepped `jmp`/`rtn`/`nopf` keeps its PC change.
* The stack convention: a push decrements SP and writes at the new SP, a
  pop reads at SP and increments, so SP is the address of the top byte and
  0(sp) the top of a frame (TT07 wrote at SP and read at SP + 1).
* Instructions stream from the QSPI flash through an 8-word window
  (`inst_stream.v`) instead of a 4-line cache: sequential code runs at the
  QSPI word rate.
* Code banks: a 7-bit code bank register (peripheral 0x15) selects the
  16 K word bank that fetches at word 0x4000 and above come from (128
  banks, 4 MB of code); `call ix`, `jmp ix`, `ret` and `rets` carry the
  bank in the pointer or the return address.
* The TTLC's program format: 12-bit slots {address, opcode}, four to a
  group of three words, a two-slot `jmp` with a 12-bit group target
  (the one-word form's jump never worked).
* `lda (ix++)`: a constant read from code space (the byte at IX of the bank
  in IX[22:16]), so constant data stays in the flash.
* The divider is a restoring divider (16 clocks): quotient and remainder
  from every division, `divc` as the chained step for wider dividends, and
  both results right for signed operands.
* Peripheral fixes: a store no longer pulses the data read strobe (a `putc`
  popped the UART's receive FIFO); UART receive overrun flags; UART2's own
  baud divisor (0x1E); per-UART interrupt enables (0x14) with level requests;
  `ldirq` loads the shadow set (it loaded nothing on the second tapeout's
  first RTL).

# Revision 3 additions

* 24-bit pointers: IX, RA and IA are 23 bits plus a condition bit, SP is
  23 bits, and the data space is a flat 8 MB through the QSPI PSRAM (the
  revision 2 data and stack bank registers 0x16 / 0x17 are gone).  `sra` /
  `lra`, `push ix` / `pop ix`, `ldxx` / `stxx` move three bytes; `ldxf`
  loads a 24-bit {cond, address}; `txah` / `taxh` move the top byte;
  `addax` / `subax` (with carry and "upper" forms) add the accumulator to
  IX; a code pointer is {cond, bank, 0, PC}.
* A SPI master (peripheral registers 0x28-0x2B) with two chip selects, a
  clock of core/2 to core/512, all four SPI modes and an interrupt on
  source 7: on its own uo_out pins (mux 2: CS0 uo[3], SCLK uo[5], MOSI
  uo[6]; CS1 uo[7] by default) or sharing the TTLC's pins in mux mode 3
  (SCLK uo[7], MOSI and the selects on the shift registers' data lines),
  taking turns with the TTLC's I/O scans.  MISO on ui_in[0], [1], [2] or [7].
* The TTLC's I/O from LISA (peripheral registers 0x2C-0x2E): the 48
  outputs, 48 inputs, 32 storage bits, port_in and RR as 18 bytes through
  an auto-incrementing index - read at any time without disturbing the
  MC14500B, the outputs and storage writable - and I/O scans LISA starts
  itself, so the shift-register chains are LISA's 48 outputs and 48 inputs
  when the TTLC isn't running.  Holding the SPI master's claim stops the
  TTLC at its next scan, for updates it must not see half done.
* The TTLC's internal storage doubled to 64 bits: bits 32-63 at I/O
  addresses 160-191 (bits 0-31 stay at 96-127), and as bytes 20-23 of
  LISA's view of the TTLC's I/O.
* Timer 3 (peripheral registers 0x30-0x3F): a 16-bit timer with a
  prescaler, two PWM outputs (uo[1] / uo[2] in mux 2, when enabled) and
  two input captures (ui_in[4] / ui_in[5]), on its own interrupt vector 9.
* A WS2812B LED string driver (peripheral registers 0x40-0x45): the pixels
  in the TTLC's output flops (two halves, sent while LISA fills the
  other), the line on one of five of the TTLC's mux-3 pins, programmable
  timing, a free-half interrupt in place of the TTLC's; and a DMA mode that
  sends whole frames from a buffer in the PSRAM through the TTLC's fetch,
  with REPEAT.
* The QSPI at clk/2 (a write-burst fix and a late read capture, debug
  register 0x1E [14:13]), DDR (DTR) instruction reads from a W25Q128JV-DTR
  class flash (0x17 [15:6]), and the custom QSPI / UART Pmod's latched chip
  selects (io mux mode 3) with a half-clock strobe.
* A cycle counter (0x48-0x4B), a watchdog (0x4C-0x4F) that resets the core
  and the peripherals, and PDM (sigma-delta) outputs as a mode of Timer 3's
  two channels.
* The quad-read mode bits are driven, so a quad flash's continuous-read
  mode is never entered by accident.
