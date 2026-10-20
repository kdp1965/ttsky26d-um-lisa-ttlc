# LISA revision 3: 24-bit IX, SP and RA

The `twenty-four-bit` branches of ttsky26d-um-lisa-ttlc, lisa-tools (lisa_sim,
sdcc_test), sdcc-lisa, nuttx and nuttx-apps (2026-10-19, Ken: "I kinda feel
like with the SB / DB scheme we gummed up the works with all these little
regions of RAM vs. just making SP and IX 24 bits to begin with, maybe RA
too, and letting push ix etc. push and pop 3 bytes").  The tapeout is
2026-12-06; rc12 (RESPIN.md, item 28) stays the fallback on `main`.

## Why

Revision 2's banks (RESPIN items 22 and 28) give 256 KB of data in 16K and
8K pieces chosen by registers.  What that costs is not the registers but
the code around them: under `sdcc --model-huge` every far data access is a
helper call that switches the bank, every call a banked call through a
trampoline, and the kernel reaches another task's memory only through a
visit on a scratch stack.  On the Arty a banktest loop iteration costs
0.7 ms, the shell's `ps` a second per task.  With 24-bit pointer registers
a far pointer loads into IX and `ldax n(ix)` just works, `call ix` and
`ret` carry the code bank themselves, the kernel sees the whole PSRAM flat
and `free` is one heap again.  The price: a third byte in every saved pair
and pointer constant, one more memory cycle on the pair instructions,
about 1% of area, and the compiler's pointer code rewritten.

## The registers

| register | revision 2 | revision 3 |
|---|---|---|
| IX | 15 bits + ix_cond | 24 bits: bit 23 the condition / code marker, 22:0 the address |
| SP | 15 bits | 24 bits (bit 23 unused by hardware, kept in pairs) |
| RA | 15 bits + ra_cond | 24 bits: bit 23 the condition bit, 22:16 the code bank, 15 unused (0), 14:0 PC |
| IA | 15 bits | 24 bits, laid out as RA |
| PC | 15 bits | 15 bits (unchanged: the window) |
| CB `[p:0x15]` | 6 bits | 7 bits: 128 code banks of 16K words, 2M words |
| DB, SB, KB | 4 / 4 / 6 bits | gone (read 0; a write is ignored) |
| A, flags, cond, amode | | unchanged |

The data space is 8 MB, bits 22:0, flat: no common region, no windows.  A
code pointer for `call ix` / `jmp ix` is a word address `{1, 0, bank[6:0],
pc[14:0]}`; a constant pointer for `lda (ix++)` is a byte address
`{1, bank[6:0], pc[14:0], byte}` (bit 23 set marks code in both).  `ldx
#imm16` loads a near value: IX <= {1, 7'b0, imm[15:0]} - the 16 bits as
given (so data up to 64K loads in two words), the bank 0, the condition
bit set as before; a code pointer below 32K words loads the same way
(`call ix` ignores bit 15).

## The instructions that change

| instruction | revision 3 |
|---|---|
| `push ix`, `sra` | three stages: the low byte at SP-1, the middle at SP-2, {cond, bits 22:16} at SP-3 (the condition bit at the lowest address, as the high byte was) |
| `pop ix`, `lra` | the mirror: {cond, 22:16} read at SP, the middle at SP+1, the low at SP+2; SP += 3 |
| `ldxx n(sp)`, `stxx n(sp)` | three stages, little-endian as before: the low byte at n, the middle at n+1, {cond, 22:16} at n+2 |
| `ldx #imm16` | two words, as above (near); its literal word is never decoded (one that looks like an `if` was executed on revision 2) |
| `ldxf #imm24` | new, three words: the opcode, the low 16 bits, then {8'h0, bits 23:16}; IX <= the 24 bits as given |
| `txa`, `txau` | A <= IX[7:0]; A <= IX[15:8] (the middle byte, no condition bit any more) |
| `txah` | new: A <= IX[23:16] (the condition bit in bit 7) |
| `tax`, `taxu` | IX[7:0] <= A; IX[15:8] <= A |
| `taxh` | new: IX[23:16] <= A |
| `adx #simm8` | IX <= IX + sext(imm8), 24 bits |
| `addax`, `subax` | IX <= IX +/- {c ? C : 0, A}, 24 bits |
| `addaxu`, `subaxu` | IX[23:8] <= IX[23:8] +/- A |
| `spix`, `xchg sp`, `xchg ra`, `xchg ia`, `cpx ra`, `cpx sp` | 24 bits |
| `ads #simm10` | SP <= SP + sext(imm10), 24 bits |
| `call ix`, `jmp ix` | PC <= IX[14:0], CB <= IX[22:16] unless that is 0, which keeps the current bank (the lower 16K words are in every bank's view, so a pointer to code there - a function pointer, a jump table loaded with `ldx` - runs under the caller's bank); `call ix` saves RA <= {cond[1], CB, 1'b0, PC+1} and post-increments IX as before |
| `jal imm15` | RA <= {cond[1], CB, 0, PC+1}, PC <= imm (the same bank) |
| `ret`, `ret #imm8`, `rc`, `rz` | PC <= RA[14:0], CB <= RA[22:16], the predicate from RA[23] |
| interrupt entry | IA <= {0, CB, 0, PC+1}; the vector and the handler in the common lower 16K words, under the interrupted CB (as before) |
| `rets` | PC <= IA[14:0], CB <= IA[22:16], the shadows restored as before |
| `lda (ix++)` | A <= byte IX[0] of the code word at {IX[22:16], IX[15:1]}, IX += 1; KB is gone |
| `lddiv`, `div`, `rem`, `divc` | unchanged operands; the 16-bit result in RA[15:0] (bit 15 as ra_cond too: `xchg ra; txau` reads the high byte whole), the other result in IX[15:0], the upper bytes of both 0 |
| a skipped `sra` / `lra` / `push ix` / `pop ix` | shifts the predicate once, like every other instruction (revision 2 never shifted it, so the instruction after was skipped too); an executed `ldxx` / `stxx` shifts it once, at its last stage (revision 2 shifted at every stage) |
| `inx`, `dcx`, `shl16`, `shr16`, `swap` | unchanged (bytes and 16-bit data on the stack) |
| `[ix+uimm9]`, `[sp+uimm9]`, `[abs9]`, `[p:abs9]` | unchanged forms; the base is 24 bits |

Encodings (free in the inherent group, checked against lisa_core.v):
`txah` 0xA014 (`10_1000_0000_0101`), `taxh` 0xA110 (`10_1000_0100_010x`),
`ldxf` 0xA190 (`10_1000_0110_01xx`).

The instruction stream, the code banking of the fetch and the window
address of a function (`0x4000 | (w & 0x3fff)`) do not change; the linker
keeps mapping banked code the same way.  The `___sdcc_bcall` trampoline
and the bank byte on the stack go away: a banked function pointer is a
24-bit code pointer and `ldxf #fn; call ix` reaches any bank.  `ldxf #sym`
is a word relocation carrying R_PAG0 and R_MSB together (sdaslisa; the
offset's third byte follows the word) that the linker's LISA code turns
into the pointer: a function's {1, bank, 0x8000 | window word} (the tag
bit 15 of the older forms stays, `call ix` ignores it; a function in the
lower 16K words has bank 0, "the current bank"), a packed constant's
{1, bank, 0x8000 | byte offset} (bank 0: the window aliases the lower 16K
words, so the same form reads it), a data address as it is.  A byte of
such a pointer is `<sym`, `>sym` and `(sym >> 16)` (sdaslisa turns the
third byte's R_HIB into R_PAG0 on the byte relocation, which the linker's
LISA code resolves the same way), so `.byte sym, (sym >> 8), (sym >> 16)`
initializes one and `ldi #((sym) >> 16)` materializes its top byte.

## The compiler (sdcc -mlisa --rev3)

Pointers: `__near` ones are 2 bytes (the first 64K of data - the direct
data of the small model, and whatever the programmer promises); every
other pointer - `__far` / `__xdata`, generic, `__code`, functions, the
address of a stack object in every model (the stack may be anywhere in
the 8 MB) - is 3 bytes with the marker in bit 23.  A `__near` pointer
loads into IX with `ldxx` and `ldi #0; taxh`, a far one with `ldxx`
alone; a generic read is `__gptrget` (`txah; btst 7` picks `ldax 0(ix)`
or `lda (ix++)`).  Frames: `sra` and `push ix` are three bytes, an
interrupt handler saves 8.  A two-byte result still comes back in IX
(stored with `txa` / `txau`: `stxx` would write three bytes), a
three-byte pointer in IX too (`stxx` / `ldxx` move it whole).  Calls: a
function of this translation unit (static, or defined above the call) or
a `__nonbanked` one by `jal`, any other `__banked` / huge-model function
by `ldxf #f; call ix`; `__sdcc_program_startup` enters `main` that way
too, so `main` may live in a bank.  The constants are packed
(`--pack-const` is implied) and read from the pointer's own bank, so
there is no KB and no constant bank to set.  The 16-bit division
results come whole from RA, so every unsigned 8- and 16-bit `/` and `%`
is native.  `jmp_buf` is 8 bytes.  The library is `lib/lisa-rev3`
(`gptrget3.s`, `memcpy3.s`, `memset3.s`, `strcpy3.s`, `strlen3.s`,
`strcmp3.s`, `setjmp3.s`; `divu.s`, `divul.s`, `divull.s` and
`bf16fs.s` carry the three-byte RA as `R` from `lisamodel.inc`).
`sdcc_test`: `make check REV3=1` (the stack at 2 MB), `test_rev3c.c`;
the chip bench: `test/run_suite.sh chip REV3=1`; SDCC's regression
suite: `make test-lisa LISA_REV3=1`.

## What it costs in the core

Registers: +9 bits in each of IX, SP, RA, IA (36 flops).  The pair
instructions gain a third stage (the sequencer's `stage_two` becomes a
two-bit stage count).  The address adders (IX + uimm9, SP + uimm9, SP +
simm10, adx) go to 24 bits; the IX-plus-offset cone is the slow-corner
critical path already, so expect about a nanosecond there and a few
percent at nominal.  The data cache tags grow from 12 bits (physical 17:6)
to 16 (address 22:7): 32 more tag flops and comparator bits over the
eight lines, five more bits on the write-back address path; its control
is unchanged, one map, the lines indexed by address bits 6:4.  The debug
port gains the upper bytes: registers 3 / 4 / 5 read and write the low
16 bits of SP / RA / IX, 0x39 / 0x3a / 0x38 the upper bytes ({cond, 22:16}
for IX and RA), 0x3c the data address bits 22:15 (register 7 keeps
{periph, 14:0}, so the lower 32K is reached as before); register 0 reports
D_BITS = 23 in bits 15:11 and PC_BITS in 10:7.  CB stays in the peripheral
block (0x15, 7 bits) with a write port from the core.  Altogether an
estimated 1% to 2% of rc12's 62654 instances.

## The plan

1. RTL (`src/lisa_core.v`, `tt_um_lisa.v`, `data_cache8.v`, `lisa_periph.v`,
   `debug_regs.v`): the widths, the third stage, the new opcodes, CB 7 bits,
   the bank registers removed, the cache tags.  `test/core` and `test/`
   programs for the pairs, the far pointers, the calls across banks.
2. lisa-tools: `lisa_sim --rev3` (the state, the stages, the disassembler,
   the frames in `lisa_cdb`), `sdaslisa` (the three opcodes, `ldxf`), the
   linker (3-byte code pointers, no bank byte).
3. sdcc-lisa `--rev3`: pointers 3 bytes native (the generic pointer helpers
   become a test of bit 23 and a load), frames with 3-byte RA and IX, the
   huge model without the trampoline.  `sdcc_test` on lisa_sim and the
   chip bench.
4. NuttX: a flat 8 MB kernel - the task banks, visits and granules removed,
   one heap, 24-bit frames; on lisa_sim, the chip bench and the Arty.
5. Harden rc13 and compare with rc12.

Status: branches made 2026-10-19 night; the design above is the contract.
Step 3 (sdcc --rev3) done 2026-10-20: the suites of sdcc_test pass on
lisa_sim --rev3 (31 programs) and the rev-2 suites are unchanged.
Step 1 (the RTL) and step 2's simulator, assembler and linker (lisa_sim
--rev3, sdaslisa's three opcodes, `ldxf #sym` relocated) done the same night: `sdcc_test/rev3/test_rev3.s` (40 checks - the
new instructions, the three-byte pairs, far data, calls and an interrupt
across code banks, the divider's results, the stack above 64K, the adders,
the predicate rules) passes on lisa_sim --rev3, the core testbench and the
chip testbench with the cache; `test/core` `make` checks the debug port's
upper bytes and RAM beyond 32K.
