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


