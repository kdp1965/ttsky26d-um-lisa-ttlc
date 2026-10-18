# LISA revision 2: the TT07 silicon issues and their fixes

The TT07 `tt_um_lisa` chip was characterized on the Tiny Tapeout demo board
(2026-10-05 .. 2026-10-09) with the SDCC port's test suite run on the chip
(`lisa-tools/sdcc_test`, `hw_test.mjs ihx=` / `spiram=`), the LISA Commander
and lisa_ide. `lisa-tools/lisa_sim` models every item below as the silicon
behaves, and `sdcc -mlisa` works around each one; the notes with the
measurements are in `lisa_isa.md` ("TT07 silicon ... notes") and
`tt07-um-lisa-ttlc/lisa-test/README.md` ("TT07 silicon notes"). This file is
the list for this revision: what the silicon does, where it is in the RTL
(line numbers of the copied tree), the fix, and how it is checked.

| #  | Issue | Where | Status |
|----|-------|-------|--------|
| 1  | Data cache aliases X and X ^ 0x4000: 16K of RAM reachable, not 32K | `data_cache8.v` 213 | fixed: cache14 |
| 2  | Read-modify-write (`inx`/`dcx`/`swap`/`swapi`/`shl16`/`shr16`) on a cache miss uses stale data | `data_cache8.v` 223, `lisa_core.v` 681-684 | fixed: test_cachermw8 (cache on: testbench, FPGA; fails with the fix removed) |
| 3  | `swap n(sp)` addresses sp + n - 512 | `lisa_core.v` 709, 630 | fixed: swap |
| 4  | BF16 `fadd`/`fsub` wrong on a significand carry-out and on a rounding carry | `fops.v` 145-166, 193-194 | fixed: test/fops |
| 5  | `ret #imm8` loads A from the wrong word | `lisa_core.v` 757, 527 | fixed: reti |
| 6  | Interrupts: predicate and pending `ldx` literal lost; `amode`, `cflag_save`, live `signed_inversion` not shadowed; `ie` unreadable | `lisa_core.v` 1206-1226, 1424 | fixed: test_irqhaz, test_irq, test_irq2 |
| 7  | ALU carry: `adc`/`sub`/`cmp` fold the carry into an 8-bit operand; `cpi` captures no signed inversion | `lisa_core.v` 643-652, 808-817 | fixed: alu2 |
| 8  | Divider: result high byte never stored, stray writes, RA and IX clobbered | `lisa_core.v` 622, 686, 736, 750 | fixed: div16 |
| 9  | A breakpoint halt right after a store drops the store and writes RAM[IX] | `lisa_dbg.v` 433-442, `lisa_core.v` 670, 714 | fixed: test_bp_after_store |
| 10 | The debugger's single step does nothing | `lisa_dbg.v` 441, core pre-decode | fixed: test_single_step |
| 11 | Debugger RAM reads return RAM[IX] with the cache off | `data_cache8.v` 223, core `dbg_ready` | fixed: test_debug_port |
| 12 | TTLC input scan shifts 17 times (every input one position high, bit 15/31/47 lost) | `shift_reg_io.v` 126-160 | fixed: test_ttlc |
| 13 | TTLC: latch pulse cannot load a 74HC166; step bit cannot work; breakpoints one late from the instruction cache | `shift_reg_io.v`, `mc14500b.v`, `ttlc_inst_cache.v` | step and breakpoints fixed: test_ttlc_debug; the 166 latch kept as is |
| 14 | Console UART holds one received byte: characters lost at flash fetch speed | `lisa_uart.v` / `lisa_rx8n.v` | done: test_uart_burst |
| 15 | Reading debug register 0xf advances PC | `lisa_dbg.v` | kept |

Status: open / fixed (the test that shows it, in test/: a program of test/progs, a cocotb test of test/core or the fops bench).

## 1. Data cache bit 14

`data_cache8.v` is the 8-line, 16-byte-line cache the chip has (`data_cache.v`
is the earlier 4-line one; both define `module data_cache`, the TT07 test
Makefile compiled the 4-line one, so the taped-out cache never ran in
simulation). Line 213 builds the SPI address of a line with bit 14 from
`cache_map[1]` when `cache_map_sel == 3`; after the move to 8 lines that is
`d_addr[5]`, not `d_addr[14]` (`cache_map[2]`), so the RAM sees
`{d_addr[5], d_addr[13:0]}` and addresses X and X ^ 0x4000 share a RAM
location through two different cache lines. Lines 214-216 (the `cache_map_sel`
0..2 variants) take the same bit.

Fix: `cache_map[2]` in 213 (and the matching bit in 214-216), the map bits
re-derived from the line geometry. Verify: a cocotb test with the SPI RAM
model on CE1 writing X and X ^ 0x4000 then reading both (`sdcc_test/test_cache*.c`
and `test_ptroff` through the cache on the chip are the program-level checks).

## 2. RMW on a cache miss

`inx`/`dcx` (`lisa_core.v` 681-682: `d_o = d_i ± 1`, combinational from the
read data), `shl16`/`shr16` (683-684), `swap`/`swapi` write back a function
of `d_i` in the cycle the cache reports a hit. After a miss the cache raises
`d_ready` (`data_cache8.v` 223: `d_valid && cache_hit`) in the first cycle
the line is valid, but the RAM's read data for that address arrives a cycle
later (the fill state machine drove the RAM address until then), so the write
uses stale `d_i`. A plain load or ALU read on a miss waits correctly; an RMW
on a byte whose line a load just brought in is right. On the chip `inx` on a
missing byte produced a constant garbage value (`test_cachermw.c`).

Fix: hold `d_ready` one more cycle after a fill (so the first hit cycle has
the RAM data), or register the read data for the RMW ops before the write.
Verify: cache test with an RMW on a cold line, and `test_cachermw` (its
`cmp`-before-`inx` workaround removed in a build) through the RAM model.

**Fixed** (0aff1c7): an RMW raises `d_we` only once its read is done
(`lisa_core.v`, `d_ok && cond[0] && (... op_inx_r ...)`). **Tested**
(2026-10-17) with `test_cachermw8` (lisa-tools sdcc_test, rev-2 build):
test_cachermw evicts with an address 0x40 away, which is the same line in
TT07's 4-line cache but another line in this 8-line one (index d_addr[6:4]),
so it never missed here and did not test the fix; test_cachermw8 evicts
with 0x80 (and puts the sp cases' byte 0x80 above a stack at 0x3fff). With
the data cache on it passes on the chip testbench (run_suite.sh chip
CACHE=1 REV2=1) and on the FPGA through the QSPI Pmod's PSRAM; with
`d_ok &&` removed from that condition it fails as TT07 did (every RMW
result 0x02, ix_rd_first alone right). The compiler's TT07 workaround (a
`cmp` touch before each inx / dcx / swap of a stack or IX byte) is only
under `--tt07-cache`, which `--rev2` refuses: no rev-2 build carries it (0
of 940 RMW ops in the rev-2 tests, 0 of 366 in lib/lisa-rev2; the
hand-written memcpy.s / memset.s touches are `.if TT07_CACHE`, 0 there).

## 3. `swap n(sp)`

`sp_sum_op` (line 709) includes `op_swap_r & inst[9]`, so the swap's address
is `sp_sum = sp + sp_adder` (638) with `sp_adder` from the default branch of
630, which sign-extends `inst[9:0]`; bit 9 is the SP-select bit of the
operand, so the address is sp + n - 512. The 128-byte RAM hides it (addresses
modulo the size); with the data cache on it exchanges a byte 512 below the
stack (`test_cacherm.c`). `swap n(ix)` and `swapi` are right.

Fix: give `swap` the same `n(sp)` address path as `ldax`/`stax` (the `sp_addr`
path), not the `ads` adder. Verify: a swap on the stack with the cache on.

## 4. BF16 adder

`fops.v`: on a significand carry-out (145-158) `f_res` is built at bits [7:0]
while the result takes the fraction from `f_rounded[8:2]` (194), so the
fraction comes back shifted right by one (1.25 + 1.25 = 2.25, 1.75 + 1.75 =
2.75). The rounding is `f_res + 2` (193: round up whenever a guard bit is
set), and its carry out of the fraction wraps to 0 without the exponent
moving (2^-35 - 1.625·2^-44 came back as 2^-36). Both on the subtraction path
too. The taped-out netlist also differs from the committed `fops.v` in a few
of 49 random additions, so the RTL is not even what is on the chip.
`fmul` (truncating), `fdiv` (Goldschmidt, within an ulp), `fcmp`, `itof`,
`ftoi` are fine, modelled in `lisa_sim/bf16.cxx`.

Fix: build the carry-out case aligned with the no-carry case
(`{2'b0, significand_add[9:2], |significand_add[1:0]}` style), renormalize
(exponent + 1, fraction 0) when the rounding carries into bit 9, and round to
nearest even. Verify: a unit testbench for `fops` against a Python bfloat16
reference (round to nearest even) over random operands and the known cases,
then `sdcc_test/test_bf16` with `<lisa/bf16.h>`'s hardware add.

## 5. `ret #imm8`

`op_reti_r: acc_load_val = {1'b1, inst[7:0]}` (757) takes the immediate from
`inst` in the exec state, but `ret_taken` (527) is combinational on the
instruction word and the return's fetch has already replaced `inst` by the
low byte of the instruction at the return address (seen on the chip; the
compiler therefore pays two words, `ldi #v ; ret`, for each byte of constant
data in code space - `lisa-tools/sdcc-lisa/src/lisa/PLAN.md`).

Fix: latch imm8 when the instruction is decoded and load A from the latch.
Verify: a program with `ret #imm8` returning into code whose low byte differs
from imm8; then `sdcc -mlisa`'s `--reti` option (stride 1 constants).

## 6. Interrupts

`lisa_core.v` 1206: an interrupt is taken in the exec state of every
single-stage instruction with `ie & cond[1]`, `cond[1]` being the value before
that instruction's own update, IA <= PC + 1, flags shadowed, PC <= vector,
`cond` left as the instruction set it. So: after an `if`/`ifte`/`iftt` the
predicate is lost (the vector word executes under `cond[0]`, and after `rets`
the predicated instruction runs unconditionally); `ldx` is two single-stage
passes (1424, `ldx_stage_two`) and an interrupt after the first word loads IX
with the vector word and executes the literal as an opcode on return. `rets`
restores `cflag`/`zflag` and `signed_inv_save` from the shadows but the live
`signed_inversion` becomes 0, `cflag_save` and `amode` are not shadowed,
`ie` cannot be read. Confirmed on the chip (`test_irqhaz.c`: 2 lost
predicates, 1 corrupted `ldx` in 20 ms with a 1 ms timer). `isr_jump` keeping
RA across the vector `jal` (1050) is right.

Fix: take an interrupt only when `cond == 2'b11` and no `ldx`/`lddiv`/`div`
stage two is pending (or shadow `cond` and the pending literal); shadow
`amode` and `cflag_save` with the flags, restore the live `signed_inversion`
from a shadow on `rets`; expose `ie` in `ldirq` (bit 3). Verify: `test_irqhaz`
and `test_irq` from `sdcc_test` on the RTL (`lisa_sim --fixed-irq` is the
reference model).

## 7. ALU carry

`acc_sum = acc + acc_adder` (652) with `acc_adder` an 8-bit operand that
already contains the carry-in: `adc #k` adds `(k + C) & 0xff` (645: `adc
#0xff` with C = 1 adds 0 and clears C), `sub M` adds `~((M + C) & 0xff) + 1`
(647: M = 0, C = 0 reports a borrow), `cmp M` with M = 0 reports a borrow
(648), and `cpi #k` sets C from a comparator but never captures
`signed_inversion` (808-817; only `add`/`adc`/`sub`/`cmp` do). A is always
right; only C and signed ordering are wrong. `add M` has no carry-in: that is
by design (`adc` is the carry form), keep it.

Fix: a 9-bit adder with a real carry-in (`acc + operand + cin`: cin = C for
`adc`, ~C for `sub`, 1 for `cmp`/`cpi` with the operand inverted), and
`cpi` capturing `signed_inversion` like `cmp`. The compiler's TT07 sequences
(`adc #0; add M`, `ldc 1; adc #~k`, the `cpi #1` guard) stay correct on the
fixed core. Verify: an exhaustive 256 x 256 x 2 testbench of `adc`/`sub`/`cmp`/
`cpi` flags against the reference, then `sdcc_test` (`test_arith*`,
`test_regress`).

## 8. Divider

Probed with `test_divprobe.c`: `lddiv`, `div`, `rem` compute right, but (1)
the result's high byte never reaches memory (the stage-two store on
`div_ready`, 686/750, does not land); (2) when the word in the instruction
register at completion has bit 1 clear (the offset word of the two-word form
for offsets 0, 1, 4, 5, ..., or the one-word `div 1`/`rem 1`) the result's
low byte is written to a stray address (IX + offset with IX already 0, or SP
+ 0x101); (3) every division leaves IX = 0 and RA = the 16-bit result (15
bits) with `ra_cond` set. `sdcc -mlisa` relies on (3): it inlines `div 3` and
the `2(sp)`/`3(sp)` forms and reads a 16-bit result from RA.

Fix: make the stage-two store of the high byte land and remove the stray
write; then decide the register side effects: keep "RA = result, IX = 0" as
the architected behaviour (the compiler already uses it; RA would need its
16th bit) or restore RA and IX. Decision needed before the fix. Verify:
`test_divprobe` and `arith-rand` on the RTL with the chosen semantics in
`lisa_sim` (`div_aftermath`).

## 9. Breakpoint after a store

A store sets `d_we_r` in exec and the RAM write completes in the next fetch
cycle. `brk_halt` (`lisa_dbg.v` 433-437) is combinational on `pc ==
breakpoint` and `stop` (442) rises in that same cycle; while stopped the core
drives `d_addr = ix` (`lisa_core.v` 714) and `d_o = dbg_di[7:0]` (670). The
store is lost and RAM[IX] gets the debugger's last data byte (measured:
stopped after `push a`, the slot kept its old contents and RAM[IX] got the
data byte of the resume command). lisa_ide and the Commander avoid planting a
stop right after a store (`Cdb::safe_stop`); an asynchronous halt can still
hit it.

Fix: let a pending write complete before the debugger takes the data bus
(gate the `stop` takeover of `d_addr`/`d_o`/`d_we` on `!d_we_r`, or register
`brk_halt` so the halt lands after the write cycle). Verify: a breakpoint
right after `push a`/`sta` in a cocotb test, RAM checked afterwards
(`hw_test.mjs hazard=` is the chip version).

## 10. Single step

Register 0 bit 2 pulses `cont` (`lisa_dbg.v` 441) for one clock; the core's
pre-decode state sees `stop` again and returns to fetch, so no instruction
executes and PC does not move. Debuggers step by breakpoints on every
successor address instead.

Fix: hold the resume until one instruction retires (a `step_pending` cleared
by the exec state). Verify: step over a `br`, a `jal`, an `ldx`, a store.

## 11. Debugger RAM reads with the cache off

With the cache disabled `d_ready` is a constant 1 (`data_cache8.v` 223), so
the core answers a register-6 read in the access's first clock, before the
pipelined address register and the RAM have seen the debugger's address; the
value latched is the RAM output for the idle address, IX. Debuggers read RAM
by writing the address to IX first.

Fix: a one-cycle `dbg_ready` after the address is presented when the cache is
disabled (the enabled cache's multi-cycle ready is right). Verify: register
6/7 reads of a pattern with the cache off.

## 12. TTLC 17-sample scan

`shift_reg_io.v` state `SHIFT_IO`: the input shift is keyed on `!shift_clk &&
clk_count == 0`, right for the 16 rising edges, but after the 16th falling
edge the FSM waits one more clock period before `LATCH` (154-160) with the
toggle suppressed by `last_clk` (126) while the shift condition is still true;
the `shift_count` decrement (150) is gated with `!last_clk`, the shift is not.
The register keeps the last 16 of 17 samples: every input one position too
high, bits 15/31/47 lost, input 0 constant. The Commander's emulator plays
this back; Ken's Pmod respin adds a 74HC175 dummy stage for the TT07 chip.

Fix: `&& !last_clk` on the input shift condition. Verify: a 74HC165/74HC595
chain model in a cocotb test (loopback of a pattern through the 48 outputs
and 48 inputs); then the Commander's 16-sample mode on the chip.

## 13. TTLC: latch, step, breakpoints

* The latch pulse is low with the shift clock still; a 74HC166 loads only on a
  clock edge while /PE is low (a 74HC165's /PL is asynchronous). Left as it
  is: a clock pulse inside the latch window would be a 17th edge to every
  existing emulator and Pmod, and the Pmods use the 165.
* `ttlc_halt = !run | step` blocked the fetch whose `ttlc_i_ready` would clear
  `step`. Now (`debug_regs.v`) the step lifts the halt until one fetch
  (`ttlc_exec`, from `tt_um_lisa.v`), then clears run; a run or step written
  passes a breakpoint on the current PC (`ttlc_skip`).
* The breakpoint compare used to clear `run` a clock after the PC reached the
  address; now `ttlc_halt` is combinational on the match, so the TTLC halts
  with the PC at the breakpoint, before its instruction. And the PC change of
  a `jmp`/`rtn`/`nopf` lands in the clock(s) after its fetch even when the
  fetch was the last one allowed (`mc14500_pcen` = run or its two delayed
  copies): a stepped jump jumps. test_ttlc_debug: a breakpoint at 5 halts at
  5 twice round the loop, three steps go 6, 7, 8, stepping round the loop
  comes back to 0 through the nopf.
* `mc14500b.v`'s WRITE strobe was two flops resetting each other
  asynchronously, which the LibreLane flow's Yosys check reported as a logic
  loop (the first GDS run of this repository failed on it); it is one
  falling-edge flop now, with the same timing (test_ttlc writes through it).

## 14. Console UART receive buffer

The core needs ~1-3 ms per received character with the flash in plain SPI
(the receive loop's instruction fetches), the UART holds one byte, so bursts
lose every other character (the monitor). A small receive FIFO (4-8 bytes)
in `lisa_uart.v`, or at least a double buffer, with an overrun flag, makes
interactive programs usable without pacing. Improvement, not a bug.

## 15. Register 0xf

Any access to the "current opcode" register increments PC (`dbg_inc`, meant
for loading code). By design; keep, and keep it out of the debuggers' polls
(documented in the Commander README).

## 16. Stack convention

TT07's `push`/`sra` write at SP and then decrement it, `pop`/`lra`
increment first and then read: SP sits one below the byte on top of the
stack, the top is `1(sp)` and `0(sp)` is a free slot every frame wastes
(`lisa_isa.md`, "Stack convention"). By design, not a bug, but Ken wants
it the usual way around (2026-10-17): decrement before the write,
increment after the read, SP at the top byte, `0(sp)` the top of the
frame. The order of the two bytes of `sra`/`push ix` stays (the high byte
with the cond bit at the lower address), so a frame's layout is the same
one address lower; every `n(sp)` offset, including `ldxx`/`stxx`,
`shl16`/`shr16`, `lddiv` and `div`'s, is one less.

Toolchain first (done 2026-10-17): `lisa_sim --rev2` models it (with the
rewritten adder, the divider without its stray write, `swap n(sp)` at sp +
n and `--fixed-irq`), `sdcc -mlisa --rev2` lays its frames out for it
(`gen.c` counts every offset from `spTop ()`, the library's `.s` write
theirs as `T+n(sp)` with `T` from `lisamodel.inc`; the lisa-rev2 library),
and `lisa_cdb` (the debuggers' frame unwinding) takes the top's offset
from `Cdb::set_sp_top`. The SDCC suite passes both ways (`make check
REV2=1`, `make test-lisa LISA_REV2=1`).

RTL (done 2026-10-17): one adder. `lisa_core.v`'s `sp_adder` gives the
push ops (`push a`, `sra`, `push ix`) −1 instead of 0 and the pop ops
(`pop a`, `lra`, `pop ix`) 0 instead of +1; the SP updates themselves
(the delayed decrement as the write completes, the increment as the read
is consumed, twice for the two-byte ops) are as they were, so each byte
lands one address lower than on TT07 and SP ends at it. Nothing else
changed (`n(sp)` stays SP + n, `ads`, `spix`, `xchg sp`, the interrupt
entry, which keeps the return address in IA). The testbenches follow it:
the probe programs in `test/progs` are built with `sdcc --rev2` (their
hand-written frames in `alu2.c`, `div16.c`, `swap.c`, `cache14.c`
renumbered; `cache14` with `--stack-loc 0x7fff` instead of `--tt07-cache`,
which `--rev2` excludes), `test_core.py` reads a pushed byte at SP, and
`run_suite.sh ... REV2=1` runs the `*_rev2.ihx` suite. Verified: the
probes and the debug-port tests on test/core, the rev-2 suite on both
testbenches (see the commit).

## 17. Debugger version

**Symptom.** A tool cannot tell which chip answers on the debug UART: TT07's
debugger reports `lisav1.2`, and the stack convention (item 16), the ALU
flags, the divider and the BF16 adder all differ between the chips.

**RTL.** `src/debug_ctrl.v`, `s_ver`: the `v` command answers `lisav2.0`
(2026-10-17, Ken's call). The major digit is the chip's revision; a tool
that sees `lisav2` or later assumes the rev-2 conventions (lisa_ide sets
its `rev2` from it at connect).

**Test.** `test/test.py` test_debugger checks the string. Note: rc2's
`gds/` (2026-10-17, earlier) was hardened before this change; the version
string is eight constant bytes in the debug controller, so it is a
re-harden with the same knobs and anchor table.

## 18. The Tiny Tapeout QSPI Pmod

**Symptom.** The chip's quad SPI and second chip select are on uio[6:7] and
uio[4] (or the custom board's latch), the Tiny Tapeout QSPI Pmod has SD2 /
SD3 on uio[4:5] and the PSRAM selects on uio[6:7]: the data cache cannot
use the Pmod's PSRAM without an interposer.

**RTL.** From ttgf-um-lisa (Ken, 2025-11): `psram_mod`, register 0x1c bit 10
(a latch beside io_mux and the TTLC shift divider; it reads back there).
With the uio mux at 2 it puts SIO2 / SIO3 on uio[4:5], CE1 on uio[6] and
uio[7] high (`src/lisa_io_mux.v`); ttgf's other mux changes are not taken.
2026-10-17; the chip testbench passes (default 3 of 3, TTLC 2 of 2).

**Test.** On the FPGA (`fpga/`, Arty A7 with the Pmod on JC, `CACHE=1
arty_run.py`): the data cache through PSRAM A on CS1, quad, runs hello,
test_core, test_printf, test_irq and the 32K tests test_bigframe and
test_ptroff (all pass); with psram_mod off test_bigframe prints nothing.
The chip testbench's PSRAM model is on the chip's own layout, so it does
not cover psram_mod.

## Verification (test/, see test/README.md)

* `test/core/`: tb_core.v, the core with the chip's registered data bus, the
  8-line cache, the RAM32 (write-first, as the DFFRAM macro reads), the QSPI
  sequencer with a QSPI RAM model on CE1 and the peripherals; instructions
  straight from an array, the debug port driven from Python. `make
  IHX=<prog.ihx> [CACHE=1]` runs a program to ALL PASSED; `make
  IHX=../progs/dbg.ihx` runs the debugger tests (breakpoint after a store,
  single step, halt / resume, RAM reads); `irq3` with `TRACEPC=` /
  `TRACEWIN=` prints a non-intrusive trace.
* `test/`: tb.v, the whole chip with a flash model (the image from
  `+FIRMWARE=`), a QSPI RAM on CE1, the debug UART and the TTLC's three
  74HC595 / 74HC165 chains. `make` runs the debugger, hello's banner and a
  burst of characters; `make TTLC=1` the loopback through the chains and the
  TTLC's breakpoints and step; `make IHX=<prog.ihx>` a program through the
  SPI fetch (Verilator: test_core in 10 s).
* `test/fops/`: fadd and fmul against an exact bfloat16 reference.
* `test/progs/`: the probe programs built by `sdcc -mlisa`, the `.hex`
  committed. `test/run_suite.sh [core|chip] [CACHE=1]` runs the SDCC suite.
* Still to do on the toolchain side: a `lisa_sim` mode for these semantics,
  `sdcc -mlisa`'s option for the shorter sequences (`ret #imm8` constants,
  the plain `adc`/`sub`/`cmp` forms, the 16-bit divider result without the
  mask), `ldamode` in the assembler and simulator, and the ISA document.

## Hardening (harden/, 2026-10-15 ..)

* The tile is 4x4 (the 8x2 of TT07 was too small with the RAM synthesized:
  ~90% utilization, detailed placement failed).
  `make -C harden` is the standard flow (RAM from `src/RAM32.v`), `make -C
  harden macro` places the RAM32 DFFRAM macro (`macro.json`) and runs the
  tile's power stripes over its met4 pins after the PDN.
* Timing: TT07 was constrained at 30 ns (`impl.sdc`, not the 20 ns in its
  config.json) and `src/lisa.sdc` keeps that and TT07's multi-cycle
  exceptions - from the PC, the instruction window (`count`, `head_addr` of
  inst_stream.v; TT07's cache line `cl_valid`, `cl_addr0`), the breakpoint latches, the debugger's address, data, write,
  halted and continue registers, the pre-decode state and `d_we_r`, to the
  registers decode writes (PC, IX, RA, IA, SP, cond, ie, isr_jump, facc, the
  divider's operands and flags). At 20 ns with only the PC exceptions the
  resizer repaired at the slow corner from -18 ns and detailed placement
  then failed (DPL-0036); the worst path after CTS was `cl_addr0` to `facc`,
  one of the missing exceptions.
* Area: the design is TT07's size (a hierarchical Yosys synthesis of both:
  184.6K against 192.4K um2; the growth is the two UART receive FIFOs, +2.8K
  each, and the new fadd, +0.6K), but LibreLane synthesized it to 229K
  because this PDK's `no_synth.cells` excludes nearly every `_1` logic cell
  and flop; TT07's build used them (its layout netlist is 24K `_1` cells of
  35K, 16.4K of its 20K logic cells; how its OpenLane 2.0.4 run got past the
  same 199-entry list is not known). Upstream open_pdks dropped the
  combinational `_1` cells from the list on 2026-05-28 (now
  `libs.tech/librelane/sky130_fd_sc_hd/synth_excluded.cells`, 23 globs), but
  every LibreLane 3.0.x release so far, the TT action's 3.0.5 included, pins
  open_pdks 8afc834 of 2025-07 with the old list. With `src/no_synth.cells` (the PDK list without the `_1`
  combinational cells and plain flops) synthesis gives 178K, placement
  utilization drops from ~79% to ~60% (standard 61.2%, macro 59.7%), setup
  is met after CTS in both flows and the post-CTS legalization passes;
  the price is more slew/cap resizing (about 200 cells against 30) and
  more hold buffers (2456 / 1432 against 1964 / 971). Before that,
  both flavours sat near 80% utilization before any repair, and the flow's
  hold buffers, setup buffers and antenna diodes pushed a full edge over:
  detailed placement failed on a few cells after the post-CTS resizer (the
  pocket beside the macro; PL_MAX_DISPLACEMENT_Y 300 lets cells leave it)
  and, for the standard flow, at diode insertion.
* Routing (2026-10-16): with the `_1` cells and placement density 85 both
  flows reached the detailed router and did not converge there: the
  standard flow's global route was 128% of the met1-met4 resources (2.56M
  um of wire for 28.6K nets) and the router diverged to 1.5M violations;
  the macro flow's global route was 74% (1.36M um, 23K nets) but the
  router sat at 20K violations after 12 iterations (29 minutes each). A
  30 um binning of the macro flow's DRC report against its placement put
  86% of the violations in bins more than 75% full of cells and the worst
  bins (above the macro's right end, under the top-edge pins) at 92-98%,
  mostly met1 shorts the size of a via landing. The target density is not
  the lever: global placement itself spreads the cells (mean 51%, one bin
  at 90% with target 85, 88% with 68) and what fills the bins comes after
  it - the slew and fanout repair (+16%: 2598 buffers in 1283 nets; with
  the `_1` cells every gate starts at the smallest drive), CTS (+4%) and
  1400 hold buffers (+10%: 1283 endpoints under the 0.1 ns margin at the
  nominal corner; TT07 had 765) - and the legalizer packs them where they
  land: 46-48 bins over 90% at either density. TT07's own layout, binned
  the same way from its GDS, has the same profile (mean 68%, 35 of 298
  bins over 90%, max 98%) and routed with OpenLane 2.0.4 on the 8x2 tile.
  GPL_CELL_PADDING 2 (a site each side of every cell in global placement,
  +35% on the 2.6 um average cell; the padded utilization is 80%, so the
  target stays 85) reserves the room: 18 bins over 90% after the hold
  buffers, the global route at 65% with an overflow of 4 (1852-3670
  before) and 1.16M um of wire (1.36M), and the detailed route is clean
  after 17 iterations in 13 minutes (30985, 22896, 21625, 5747, 1748 ...
  3, 0 violations). The standard flow (RAM
  synthesized) is out of reach on this tile: its global route needs 128%
  of the resources at density 85 and 144% at 70 (2.56M / 2.76M um for
  28.6K nets), and the GitHub run of it hit the runner's 6-hour limit in
  detailed routing at 575K violations. `make -C harden macro TILES=8x2`
  runs the macro flow on the TT07 tile with TT07's placement
  (macro_8x2.json), meant as the check against the tools; but this design
  is 5% bigger than TT07's after the flow (192K against 182.5K um2 of std
  cells) and on that tile it places at 69%, ends with 88 bins over 90% and
  a global route at 113% of the resources, so the comparison needs TT07's
  own netlist and was not pursued. `make TO=OpenROAD.GlobalRouting` stops
  after the congestion report.
* Signoff of the first routed build (padding 2; 2026-10-16): the router,
  antenna check (0 after repair) and wire-length check passed, hold is met
  at every corner (worst +0.108 ns), setup is +5.1 ns at the nominal corner
  but -9.4 ns at the slow one (ss, 100 C, 1.60 V; 250 endpoints) where the
  post-CTS repair had left +0.18 ns, with 11297 max-slew and 775 max-cap
  violations after extraction. The paths run through the fanout buffers:
  LibreLane keeps the resizer off only the PDK's `drc_exclude.cells`, and
  OpenROAD starts every fanout, wire and port buffer from the weakest
  buffer it may use, which on sky130 is the delay cell `clkdlybuf4s25_1`:
  1548 of the 1589 fanout buffers (TT07's OpenLane 2 build has buf_2,
  clkbuf_4, clkbuf_2 and buf_4 there), each 1.0-1.85 ns at the slow corner
  with 1.3-1.8 ns slews. `EXTRA_EXCLUDED_CELLS` in src/config.json now
  keeps the delay cells (clkdlybuf4s25/50, dlymetal6s*, dlygate4sd1/2) out
  of the repairs; `dlygate4sd3_1` stays for the hold buffers. The flow then
  stopped at the IR-drop step: `check_power_grid` found the macro's VGND an
  island - the two full-height stripes the Tile.ExtendPowerStripes step
  draws over the macro's VGND pin columns are 5.3 and 7.2 um off the
  nearest tile stripes and touched nothing else, and VPWR passed only
  through a 0.57 um overlap of one of its three with a tile stripe (TT07's
  build drew the same stripes, as tile power pins, and relied on the
  chip-level straps). The step now adds via stacks (M1M2_PR, M2M3_PR,
  M3M4_PR, two per crossing) from each added stripe to every rail of its
  net above the macro, as pdngen does for its own stripes.
* Second routed build (delay cells excluded, via stacks; 2026-10-16): routed
  clean (40 iterations), antenna clean, LVS clean (netgen: circuits match
  uniquely), both power nets connected with 0.1 mV of IR drop, hold met at
  every corner; setup +5.2 ns nominal, -5.5 / -6.9 ns at the ss corners
  (115 / 163 endpoints) and still 2681 max-slew violations at the nominal
  corner (0.75 ns limit, slews 0.8-2 ns on fanout nets; the fanout buffers
  are now `buf_1`, the weakest buffer left). Magic DRC: 2175 errors, all at
  the hand-made via stacks (met3 minimum area on the single-via pads, via
  spacing to the neighbouring tile stripe's arrays) - replaced by
  `harden/pdn_macro.tcl` (`PDN_CFG`): pdngen itself puts a stripe with its
  via arrays on each macro pin column that is not on a tile stripe (the
  offset is the centre of the first stripe: VPWR at 19.08 + k * 38.87 um,
  VGND 3.3 um after), and the extension step only bridges over the macro.
  The slow-corner paths all start at the PC and end at the rev-2 interrupt
  shadows (`cflag_isr`, `zflag_isr`, `signed_inv_isr`, `cflag_save_isr`,
  `signed_inv_live_isr`, `amode_isr`), written in the same clock and branch
  as `ia`, `isr_jump` and `ie` when the interrupt is taken - lisa.sdc now
  lists them with those (3 cycles). Left as they are, for Ken: PC ->
  `acc_delayed_val` (same slack, the RMW-on-a-miss delayed accumulator, a
  different write condition) and the debugger's `fetch_r` -> `facc` (-5.8
  ns at ss, +5 nominal). The pre-route estimate is far from the extracted
  wires here (everything met before routing), so `RUN_POST_GRT_DESIGN_REPAIR`
  and `RUN_POST_GRT_RESIZER_TIMING` were turned on for the third build (the
  slew/cap and setup/hold repairs again after global routing with its
  parasitics) - and off again after it, see the next bullet.
* Third build (all of the above with the post-GRT repairs; 2026-10-16)
  stalled in detailed routing: 2893 violations after 13 iterations, 2848 of
  them met1/met2 shorts in one 150 x 110 um region at the top left (the
  debugger's UART and autobaud flops), nothing near the macro or the new
  straps. No cells overlap; the 1000 "missing route to pin" warnings of the
  post-GRT steps are the RAM macro's nets and touch 6 violations. That
  region's rows were 92% full before routing against 88% in the second
  build (44 more flops and 45 more hold buffers placed there: only the PDN
  script and the post-GRT steps differ in the configuration, the placement
  just landed differently). Four router iterations on the build's own
  states: from the state before the post-GRT repairs 1308 violations in
  the region instead of 4105 (the repairs add 19 buffers and 60 upsizes
  and re-legalize, mirroring 9877 instances, after the global route); with
  the clock tree's 2x-spacing rule removed 3673 (no effect; the router
  disabling it "to reduce congestion" was a symptom). So
  `RUN_POST_GRT_DESIGN_REPAIR` / `RUN_POST_GRT_RESIZER_TIMING` are off
  again (fix4, `harden/trial_fix4.json`), and fix3 (`trial_fix3.json`) adds
  a site of padding each side of every buffer and delay cell at
  legalization only (`DPL_CELL_PADDING` 2 with `CELL_PAD_EXCLUDE` naming
  every other family - OpenROAD matches them with `string match` globs), so
  the flow's post-placement additions must find room instead of packing
  the flop clusters. Per-run overlays: `make macro OVERLAY=file.json`.
  Note the global placement is not deterministic run to run (fix4, the
  same configuration as fix2 up to routing, placed differently from its
  first step: that region's rows 90% full instead of 92%), so a build
  near the threshold is a lottery and the margin has to come from the
  configuration. fix5 (`trial_fix5.json`) takes the prism route instead:
  the registers are pinned (DEF FIXED) where the second routed build had
  them before global placement and released after it
  (`harden/seq_placement.py` extracts the table from a run's ODB, keyed by
  the RTL name on each register's Q net - 2327 of 2337 carry one -
  `odb_anchor_seq.py` / `odb_anchor_release.py` apply it as the
  `Project.AnchorSequential` / `Project.ReleaseAnchors` steps of flow.py,
  `ANCHOR_SEQ_TABLE`), so that build's register skeleton is reused and
  the placer only arranges the logic around it. fix3 was stopped: the
  padded buffers were legalized far from where the resizers put them (47
  mm of total displacement at the first legalization, 142 um max), the
  global route came out at 75% usage with an overflow of 3028 (fix4: 67%,
  225) and the detailed router was still in its first iteration after 40
  minutes with 37K violations - padding at legalization is not the lever
  either. fix2 was stopped at the same time (13 iterations, 2893).
  fix5's registers were all pinned (2327 found, none moved) but its logic
  still packed the region to 91.5% - the flop skeleton alone does not
  carry the reference's logic distribution here. fix6 (`trial_fix6.json`)
  pins the combinational cells too, prism's part 2: `odb_anchor_cells.py
  --dump` writes the reference's logic graph with its placement
  (`placements/macro-fix_final_cells.json`; buffers collapsed, registers
  keyed by name, every other net keyed by its driver's function and
  inputs, then a neighbourhood hash for what the exact keys miss) and
  `ANCHOR_CELLS_TABLE` pins what matches: 18682 of the 18698 logic cells
  (all registers, 16 combinational cells left to the placer), so the
  reference placement is replayed and only the flow's buffers are new.
  fix5 was stopped at routing: with the registers fixed the placer gave
  the logic a global route of 78% usage and an overflow of 4081 (fix2:
  69%, 859; fix6: 65%, 81). Results: fix4 routed clean after all (its
  region had come out at 90%; the router sat on 3 violations from
  iteration 22 to 40 before clearing them; 91 minutes) and fix6 routed
  like the reference (clean at iteration 16, 32 minutes for the whole
  flow). Both: Magic DRC 0 (the pdngen straps did it), LVS clean,
  antenna clean, IR drop 0.6 mV, hold met at every corner, setup +5.2 ns
  nominal; the wirelength of fix6 equals the reference's. fix6 is the
  build to submit and `trial_fix6.json` the recipe (now macro.json's
  default, `ANCHOR_CELLS_TABLE`): the placement no longer depends on the
  draw.
* Open at signoff (both builds), for Ken: setup at the ss corners only
  (-6.9 ns max_ss, -5.8 nom_ss; nominal and ff are met with 5-6 ns of
  margin). Every violating path is an exception question, not a
  physical one: the PC into state registers the `lisa.sdc` PC list does
  not name (`acc_delayed_val` -7.1, the divider's `cflag` -7.0,
  `acc_delayed_load` -6.6, `d_we_r` -6.1, `stage_two` / `exec_state`
  -5.9, `cflag_save` / `signed_inv_save` -5.8, the debugger's `fetch`
  -5.5, `stg2_state` -5.2, the divider's `op_start` and
  `lddiv_stage_two` -4.9, `delayed_sp_dec` -3.7), the debugger's `skip_r`
  into `facc` (16 bits, -6.0), `dbg_we` / `dbg_a` into the divider's
  `signed_inversion` / `zflag` (-2.6), and `d_addr` / `cl_addr0` into
  `ra`, `pc`, `ix`, `div_rs1` (-2.4). If a PC-to-state path is
  two-cycle by construction (the fetch in between), it belongs in the
  PC list of lisa.sdc; the others need a look at the RTL. The max-slew
  count at the nominal corner (2.7K nets over 0.75 ns, fanout nets at
  0.8-2 ns; 12.5K at ss) stays: the post-GRT repairs were the wrong
  tool (above); `DESIGN_REPAIR_MAX_SLEW_PCT` before placement would be
  the next one to try, at the cost of more buffers in the dense bins.
* First submission (fix6's GDS through `gds_custom.yaml`, 2026-10-16): the
  GDS job passed, Tiny Tapeout's precheck failed its pin check - "Port VGND
  is too far from bottom edge of module: 154.12 > 10 um", six power port
  boxes. pdngen cuts its stripes around the macro (its straps on the pin
  columns start above the halo, and so do the two tile stripes that pass
  within its clearance of a macro pin, 291.17 and 368.91 um), and each cut
  stripe is also a box of the tile's power port; the extension step's
  full-height boxes sat beside them in the DEF but Magic's LEF kept the cut
  ones. The GDS itself was whole (one full-height met4 polygon on every
  pin column). `odb_stripes.py` now replaces every met4 power pin box
  shorter than the core with a full-height one and completes the stripe
  over the macro (same net on the pin columns; the 368.91 tile stripe
  passes the VGND pin at 0.37 um, met4 spacing is 0.30); fix7 is the
  rebuild: 25 minutes, routed clean, Magic DRC 0, LVS clean, antenna
  clean, IR drop 0.6 mV, hold met, setup +5.2 ns nominal (-7.4 at ss,
  the same exception questions), and its LEF's 39 power port boxes all
  reach both edges. (pdngen's own PSM-0069 "check connectivity failed"
  in the GeneratePDN log is expected: it runs before the extension step
  bridges to the macro pins; the IR-drop step then reports every shape
  connected.) fix7's GDS, LEF and netlist were the submission until the
  release candidate below.
* A smaller RAM32 (2026-10-16, afternoon): DFFRAM.librelane (branch
  ihp-cfgmem, commits 6ace631 and 9f2269b) now builds the macro in 320.16 x
  116.96 um instead of 401.58 x 136 (-31%): the placer's nine near-empty
  rows were an artifact (a 16-word block's side column of buffers ran past
  the block; a tie-cell row; two spare rows), and `models/ram_ao` replaces
  the 1088 tri-state buffers with a nand2 per bit per word, two nand4 per
  bit per slice and an or4 per bit per block (same ports and pin sides; the
  generic testbench passes on the routed netlist; DRC 0, LVS clean, no
  antenna violations, setup +3.7 ns nominal / +1.8 at ss in DFFRAM's own
  16.5 ns STA). Its 8 + 8 power pin columns sit on the tile's 38.87 um
  stripe pitch at the tile's offsets, so in this tile the macro's origin x
  must be a multiple of 38.87 (then every column coincides with a same-net
  tile stripe, pdn_macro.tcl adds nothing and the extension step completes
  the cut tile stripes over it); 2.65 um off, the cut VGND stripes could not
  be completed across the VPWR pins. Trial in LISA (`harden/trial_ao.json`:
  views in `macros_ao/`, macro at x = 349.83, horizontal halo 10 so no row
  is left between the macro and the core edge - pdngen cannot power a 3.7 um
  sliver): runs/macro-ao3 signed off - routed clean, Magic DRC 0, LVS
  clean, antenna clean, IR drop 0.06 mV (0.6 with the old macro), hold met,
  setup +5.6 ns nominal (+5.2 before), -7.0 at ss (the SDC items above),
  utilization 64% (69%), every power port box full height. Not the
  submission yet: adopting it is a copy of `macros_ao/` over `macros/`, the
  location and halo into macro.json, and a rebuild. Ken's point: the
  anchored placement leaves the freed 80 x 136 um to decap, so
  `trial_ao_free.json` runs the same with no anchor table - the placer's
  (padded) utilization drops from 80% to 75%, the dense bins from 18 to
  15, the UART/debug corner's rows to 86%, and runs/macro-ao4 signed off
  on its own draw: routed clean in 20 iterations (clean builds: 24-40),
  Magic DRC 0, LVS clean, antenna clean, IR drop 0.3 mV, hold met, setup
  +5.5 ns nominal / -6.1 at ss (the best so far; fix7 -7.4, ao3 -7.0),
  wirelength 829K um, utilization 65%, every power port box full height,
  20 minutes. The smaller macro moves the design away from the
  routability threshold; an anchor table dumped from ao4
  (`placements/macro-ao4_final_cells.json`) makes that draw repeatable.
  Ken's next question: is the halo needed, especially below the macro?
  No: every tile pin is on the top edge and in ao4 not one net segment
  crosses the 10 um under the macro, yet the halo cost 48 rows for a
  43-row macro (at y 10 the macro straddled two rows and the 6 um halo
  rounded to whole rows above and below) plus 10 um on its left.
  `trial_ao_tight.json`: the macro on the core's bottom row (y 2.72, on
  the row grid; its rows are then flipped against the tile's, harmless
  across the halo - y 5.44 would match them at the cost of the row under
  it), vertical halo 1 um (cut_rows cuts the row that overlaps the halo
  box, not one that only touches it, so exactly the row on the macro's
  top edge goes), horizontal halo 2 um, and FP_PRUNE_THRESHOLD 11
  (cut_rows' -row_min_width) dropping the 17-site row stubs between the
  macro and the right core edge instead of a 10 um halo swallowing them:
  44 rows lost instead of 48, 4600 um2 (1.4% of the core) back.
  runs/macro-ao5 signed off: routed clean in 11 iterations, Magic DRC 0,
  LVS clean, antenna clean, IR drop 0.3 mV, hold met, setup +5.5 ns
  nominal / -5.8 at ss, wirelength 812K um (829K), dense bins 14 (15, the
  densest 0.99 against 1.06), every power port box full height, 18
  minutes. The area is small (the freed rows hold the same logic/fill mix
  as before and the fill grew by the same 5000 um2) but the margin it
  gives the router is real. The DFFRAM macro keeps its own 2.72 um row
  margin top and bottom and 1.38 um left and right, so the tile's cells
  are never closer than that to the macro's.
  ao5 is the release candidate (2026-10-16, evening): `macros/` holds the
  AND-OR macro, macro.json its position, halos, FP_PRUNE_THRESHOLD and the
  ao5 anchor table, `gds/`, `lef/` and `pnl/` are ao5's (commit 85f18be,
  tag rc1), and gds_custom.yaml run 39000647237 PASSED the precheck.
* A streaming instruction fetch (2026-10-17): lisa-tools/lisa_sim's cache
  model (`--icache`, `make icache` in sdcc_test) measured the TT07 fetch on
  the SDCC suite: 85-90% of the clocks in QSPI line fills, 86% of the
  misses on the next sequential word, so a 4-line cache (Ken's question)
  gains 0-17% and a second 32x32 macro 1.0-1.7x, while keeping the flash
  read open gains 1.7-2.6x. `src/inst_stream.v` replaces `inst_cache.v`:
  a burst is started at the word the core asks for and the QSPI engine
  keeps clocking the following words into a window of 8 (10 clocks each),
  pausing with chip select low when it is 3 words ahead of the core; the
  words behind the core stay (up to 4), so loops of five instructions or
  fewer - every polling loop - run from the window; a fetch of the word
  the burst delivers next is waited for, any other word the window does
  not hold ends the burst and starts one there (about 67 clocks: command,
  address, dummies, the word). `lisa_qqspi.v` got the open-ended burst
  (`stream`: no length, paused in S7 until the client takes the word,
  ended at once when the client drops it) and `lisa_qspi_controller.v` a
  yield to the instruction client when another client waits, honoured
  once the words ahead are in, after which the burst goes on from where
  it was when the bus is free. The first version did it in one FIFO and
  was slower on every UART-bound test: the words behind the core were
  dropped and the two-instruction UART poll restarted the burst on each
  iteration. Two deadlocks found by waveform (`make ... DUMP=1`, now a
  real trace under Verilator): a burst's first word held by the engine
  with no room for it because the window counted three words "ahead" of
  the last word taken while the core had moved past them, and `miss`
  asserted on every clock the core waited for a burst's first word, which
  latched an abort and tore down every burst after one word; then, after
  a yield, a jump two words past the window counted as a wait but the
  restart needed room computed from the stale position. The window's
  position now follows the core's address on a hit or a wait. Every chip
  testbench matches the old RTL: the debugger, bringup and UART burst
  tests, the suite (16 pass, the same 5 fail: bigframe, irq, bf16's
  adder cases, ptroff, divl's silence timeout), the data-cache suite
  (8 pass, test_cacherm's TT07 expectation) and both TTLC tests. Measured
  with `STATS=1` (counters in tb.v over the program's run, 50 MHz, the
  UART at 720 clocks a character): test_divl, compute-bound, 42.5M to
  18.9M clocks (2.25x); test_pfu 2.28M to 1.14M (2.0x), its clocks waiting
  for the fetch 80% to 58%, QSPI transfers 21584 of 4 words to 3373 of
  24; test_strs 1.16x and test_loop 1.15x; test_core 1.0x (46% to 24%
  waiting, the rest of its time in the UART poll). The remaining wait is
  the QSPI word rate, 10 clocks a word at SCLK = clk/2 against 3-4 clocks
  an instruction. Standalone synthesis: inst_stream 9529 um2 (159 flops)
  against inst_cache's 3909 (84), +1.6% of the core. Hardened the same
  day (below); rc2 adopts it.
* Hardening the streaming RTL (2026-10-17): 3% more standard-cell area
  than rc1 (144.6k against 140.1k um2 synthesized, 189k against 183k
  placed, 76% utilization) put the padded placement at its density limit
  and the router stalled on every draw: free (overlay trial_ao_tight.json)
  global-route overflow 1707 and 12K violations after 12 iterations, each
  slower than the last; anchored to rc1's table (6448 cells matched after
  the RTL change, the rest free) overflow 263 and 149 in two draws, the
  first down to 1 violation stuck for four iterations of 50 minutes, the
  second on the same path. The violations sat in whichever corner the
  draw packed to 90% in 30 um bins: the debug UART cluster top left (x
  30-150, y 390-510) or the TTLC shift_reg_io block top right (x 600-660,
  y 420-480), 71-77% in rc1. Padding was already 2, so the lever had to
  be area, measured in 8-minute runs to global routing (`make macro
  TO=OpenROAD.GlobalRouting OVERLAY=...`): MAX_FANOUT_CONSTRAINT 10 -> 16
  (trial_fanout16.json) removed 480 of the 3026 repair buffers but
  repair_design upsized their drivers instead, no area back (overflow 149
  -> 115); the hold margin PL_RESIZER_HOLD_SLACK_MARGIN 0.1 -> 0.05 ns
  (trial_fanout16_hold05.json) took the 1346 hold buffers to 191 - the
  flop-to-flop paths sit in a 50-100 ps band of raw hold slack at the
  fast corner, about 400 buffers per 10 ps - 11k um2 back, overflow 59,
  the corners at rc1's density; 0.07 ns (trial_fanout16_hold07.json) 591
  buffers, 7.4k um2 back, overflow 35, 8 bins over 90% against rc1's 14.
  Both routed clean in 12-14 iterations, 45 minutes end to end, Magic DRC
  / LVS / antenna 0, setup +5.5 ns nominal and -6.1 / -7.2 at ss (rc1
  -5.8), hold worst slack 0.056 / 0.077 ns at the fast corner (rc1 0.109),
  max-fanout violations 36 / 35 (146), max-slew 7900 / 8040 (11320).
  Ken chose 0.07 (runs/macro-stream-fo16-hold07): `gds/`, `lef/`, `pnl/`
  are its results, macro.json carries the two knobs and its placement as
  the anchor table (placements/macro-stream-fo16-hold07_final_cells.json;
  ao5's kept) - rc2, the release candidate for the streaming fetch and the
  stack convention (item 16).
* Found on the way: Yosys names a flattened net after any alias (the
  debugger's data bus is `core_inst_o[*]` in the netlist), the breakpoint
  registers are latches, and OpenSTA's `read_sdc` fails on an exception
  command whose text holds an inline `[expr {...}]` (it takes the command
  text as a list to record the SDC line).
* After rc2 (2026-10-17, evening): the FPGA port (`fpga/`, the Arty A7 with
  Vivado) runs the same RTL with lisa.sdc's exceptions on its netlist, and
  at 50 MHz the longest single-cycle path left was the instruction window's
  words into the BF16 accumulator (window -> the fadd operand select -> the
  adder -> facc). Ken: a 3-cycle path, fetch / decode / exec - lisa.sdc
  gains `win_data` (`i_inst_stream.window[*]`, 128 flops, 3 cycles into
  core3 and 2 into core2 like the window's count and head; the flow to
  STAPrePNR resolves it, every other count as rc2's). rc2 was signed off
  without it and without item 17's version string: the next harden is rc3.
  Seen in the netlist on the way: lisa.sdc's `div_rs1` / `div_rs2` group
  names nets of combinational operands, so its register walk resolves to
  the IX low byte and the accumulator (8 + 8), giving pc -> acc[7:0] and
  pc -> ix[7:0] two cycles; and its `cont_q` walk finds only `cont_q_r`,
  not the `step_r` / `skip_r` levels the RTL ORs into cont_q (the FPGA
  has them in the group; the chip's SDC is Ken's call).

* The suite's known failures, first test_bf16 (2026-10-17): its checks 33
  and 34 asserted the TT07 adder's two defects through `bf16_fadd_raw` and
  so failed on the rewritten adder, which gets them right. The test now
  probes which adder is there (1.75 + 1.75: 3.5, or TT07's 2.75) and expects
  the defects or the right answers accordingly, and on the fixed adder
  checks the raw add on its other vectors too (nearest even, the
  infinities, NaN, the smallest normals); it passes here and on lisa_sim's
  TT07 model (lisa-tools 8fd7e53). `sdcc -mlisa --rev2` (sdcc-lisa
  47ad0a4) now links a library whose `bf16_add` is this adder (15
  instructions instead of the software addition; `--bf16-float`'s
  additions too); test_bf16 and test_bf16f built with it pass here.

* test_divl (2026-10-17): no error in it, the suite runner's 6M-clock
  silence limit. Its last block, 200 LCG divisions against a bit-serial
  reference in C, printed nothing for about 18M clocks (40M before the
  streaming fetch). The test now prints a mark every 16 iterations
  (lisa-tools a453dec) and passes with the default limit. Left on the chip
  testbench: test_bigframe and test_ptroff, which need the data cache
  (they pass in the CACHE=1 list), and test_irq, which prints nothing.
  Since 2026-10-17 run_suite.sh lists test_bigframe and test_ptroff under
  CACHE=1 only (the 32K data space they are built for, --stack-loc
  0x7fff): the default list is 19 programs, all passing on both benches,
  the CACHE=1 list those two (plus the TT07 cache tests for a TT07 build).
* test_irq (2026-10-17): the test's timer, not the chip. Its tick came
  every 640 clocks (TIMER1_DIV 20) into a byte counter: lisa_sim ran
  work(300) in 135K cycles (212 ticks), the core testbench at 3-4 clocks
  an instruction overflowed the byte (check 3 compares the 16-bit sum
  with the count) - it had failed there since 2026-10-15 (test/core/
  r_irq.xml) - and on the chip testbench the ~50-instruction handler took
  longer than the period, so nothing was ever printed. The counter is 16
  bits and the tick every 3200 clocks (lisa-tools sdcc_test/test_irq.c,
  test/progs/irq3.c): 43 ticks on lisa_sim, 183 on the core testbench,
  passes on both testbenches and both simulator modes.

## Decisions (Ken, 2026-10-15)

* 8, the divider: whatever gives the most efficient code, with a compiler
  option for the fixed core. So: no memory write of the result at all (the
  high-byte store was broken and the stray write goes with it); the 16-bit
  result stays in RA with its bit 15 in `ra_cond`, so `xchg ra` gives the
  whole result in IX (`txau` then reads bits 15:8, no `andi #0x7f`) and
  `stxx` stores it; IX is 0 afterwards as on TT07. `sdcc -mlisa` keeps the
  TT07 sequences by default and gets an option (`--rev2`, name to be
  settled) for the shorter ones.
* 6, interrupts: shadow everything the handler would otherwise have to save
  (amode, cflag_save, the live signed inversion, as `lisa_sim --fixed-irq`
  already models) and expose `ie`.
* The RAM: the RAM32 DFFRAM macro, as on TT07 (the local flow). To look at:
  the macro's read path is 1088 `ebufn_2` tri-state buffers (the 32:1
  column mux per output bit, ~13.6K um2) next to 1024 `dlxtp_1` latches
  (~14K um2) in a 401.6 x 136 um = 54.6K um2 block that is a third decap
  (825 `decap_12`); an AND-OR (mux2 tree) read path would be about half
  the area of the tri-states, so a recompiled macro could come in around
  40K um2. Not started.
* 14: an 8-byte UART receive FIFO.
* `amode` becomes readable.
* 7: `add` stays carry-less (confirmed 2026-10-06).
