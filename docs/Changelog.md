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

# Revision 3 additions

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
  timing, a free-half interrupt in place of the TTLC's.
* A 5x4 tile (856.52 x 511.36 um) with room to grow, and Calvin drawn into
  the standard-cell rows as placement blockages.
