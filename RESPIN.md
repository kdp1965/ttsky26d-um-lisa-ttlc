# LISA revision 2: the TT07 silicon issues and their fixes

The TT07 `tt_um_pettit_lisa` chip was characterized on the Tiny Tapeout demo board
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
| 14 | Console UART holds one received byte: characters lost at flash fetch speed | `lisa_uart.v` / `lisa_rx8n.v` | done: test_uart_burst; the overrun flag in the status (bit 2 / UART2 bit 3): test_uart_overrun |
| 15 | Reading debug register 0xf advances PC | `lisa_dbg.v` | kept |
| 16 | Stack convention: SP at the top byte, `0(sp)` | `lisa_core.v` sp_adder | done: test/progs --rev2 builds, run_suite REV2=1 |
| 17 | Debugger version: the second chip answers `lisav2.0` | `debug_ctrl.v` | done: test_debugger |
| 18 | The Tiny Tapeout QSPI Pmod's pin order (psram_mod) | `lisa_io_mux.v`, `debug_regs.v` 0x1c bit 10 | done: the FPGA, cache on |
| 19 | TTLC program format: 12-bit slots, four to three words; the old `jmp` never worked | `ttlc_fetch.v`, `tt_um_pettit_lisa.v`, `debug_regs.v` | done: test_ttlc, test_ttlc_jump, test_ttlc_debug |
| 20 | The autobaud and BRG count in 32-clock steps: only rates with a bit a multiple of 32 clocks | `debug_autobaud.v`, `debug_brg.v` | done: test_autobaud; the FPGA at 115200 .. 921600 |
| 21 | Quad flash reads float the mode bits: continuous-read mode by accident | `lisa_qqspi.v` S12_MODE | done: the FPGA quad on both selects |
| 23 | A store to the UART data register pops the receive FIFO (the core's `d_rd` pulsed on a store's exec clock); any access to 0x14 wrote UART2's baud divisor | `lisa_core.v` d_rd, `lisa_periph.v` 0x1E | fixed: test_uart_overrun |
| 24 | `ldirq` loads nothing: a misc load (101000..) decoded by `op_ld_misc_r` first, its own case item never reached; `stirq` then wrote A back as the shadows and `rets` restored amode 0 | `lisa_core.v` acc_misc | fixed: sdcc_test/test_ldirq (lisa_sim --rev2, the testbench, the Arty) |
| 25 | The UART interrupt enables (0x14) have no write decode - TT07 too: `uart_rx_ie` / `uart_tx_ie` read 0 and no UART interrupt ever fires; the request was an edge, latched | `lisa_periph.v` 0x14, int_req | fixed: the enables written, the UART requests levels (Ken, 2026-10-18); sdcc_test/test_uartirq (lisa_sim --rev2 --send, the testbench with SEND=, the Arty) |
| 26 | An extension: `lda (ix++)` (0xA14C) reads byte IX[0] of the code word at {KB, IX[14:1]} and increments IX, KB the constant bank register 0x1F - constants packed two to a word in any bank (the `ldi; ret` pair per byte took 4 flash bytes and the common area) | `lisa_core.v` op_ldk, `lisa_periph.v` 0x1F, `tt_um_pettit_lisa.v` core_i_paddr | done: sdcc_test/test_ldk (lisa_sim --rev2, the testbench) |
| 27 | An extension: the divider's second result and a chained step. `div` leaves the remainder in IX (`rem` the quotient; TT07 and rc10 cleared IX), and `divc` (0xA174) divides {IX, A} by the divisor of the last division, the quotient byte to A / RA and the remainder to IX - a long division of any width by a 16-bit divisor in one `divc` per byte (SDCC's 64-bit division is a 20K-instruction bit-serial loop); the divider is a restoring one now, 16 clocks | `lisa_div.v`, `lisa_core.v` op_divc | done: sdcc_test/test_divc (lisa_sim --rev2, the testbench) |
| 22 | Bank registers (an extension): the upper 16K of the code and of the data space a window on 64 code / 16 data banks, 2 MB / 256 KB | `lisa_periph.v` 0x15-0x17, `tt_um_pettit_lisa.v`, `inst_stream.v`, `data_cache8.v`, `lisa_core.v` d_sp | done: test/progs/bank.c (make BANK=1), lisa_sim --rev2, sdcc __banked (sdcc_test/test_bank on the testbench and the Arty) |
| 29 | An extension: a SPI master on its own pins - the core reaches a SPI flash or SD card without the QSPI bus its instructions come from (a fifth QSPI client could deadlock on the core's own fetch) - on the mux-2 pins or shared with the TTLC's pins under an interlock with the scan | `lisa_spi.v`, `lisa_periph.v` 0x28-0x2B, `lisa_io_mux.v`, `tt_um_pettit_lisa.v` ttlc_scan_pend | done: test/progs/spi.c (make SPIM=1: test_spi, test_spi_ttlc), sdcc_test/test_spiflash (lisa_sim --rev3 --spi-flash) |
| 30 | An extension: the TTLC's I/O from the core - the 139-bit I/O vector as 18 bytes (read any time, the outputs and storage writable), scans the core starts, and atomic updates under the SPI master's claim | `lisa_ttlcio.v`, `lisa_periph.v` 0x2C-0x2E, `ttlc_io.v` byte port, `tt_um_pettit_lisa.v` ttlc_io_start, `lisa_io_mux.v`, `lisa_spi.v` go | done: test/progs/ttlcio.c (make TTLCIO=1: test_ttlcio, test_ttlcio_run) |
| 31 | An extension: the TTLC's storage doubled to 64 bits - bits 32-63 at I/O addresses 160-191, bytes 20-23 of the core's view | `ttlc_io.v` temp_storage, read_values; `lisa_ttlcio.v` TIDX to 23 | done: test/progs/ttlc/ttlc_storage.asm (make TTLC=1 TTLC_IMAGE=progs/ttlc_storage_test.hex), test/progs/ttlcio.c checks 1, 0x0d, 0x0e |
| 32 | An extension: Timer 3 - 16 bits with a prescaler, two PWM outputs (uo[1] / uo[2] in mux 2, when enabled; UART2's transmit otherwise) and two input captures (ui_in[4] / ui_in[5]), interrupt source 8 on vector 9 | `lisa_timer3.v`, `lisa_periph.v` 0x30-0x3F, `lisa_core.v` int_i 9 bits, `lisa_io_mux.v` periph_sel1[2:1], `tt_um_pettit_lisa.v` | done: test/progs/timer3.c (make TIMER3=1), sdcc_test/test_timer3.c (lisa_sim --cap-wave) |
| 33 | An extension: a WS2812B LED string driver - the pixels in the TTLC's 48 output flops (two halves), the line on one of mux 3's uo[0], [1], [2], [5], [6], programmable timing, the free-half request on the TTLC's interrupt source | `lisa_ws2812.v`, `lisa_periph.v` 0x40-0x45 and int_req[5], `lisa_io_mux.v` periph_sel2, `tt_um_pettit_lisa.v` | done: test/progs/ws2812.c (make WS2812=1), sdcc_test/test_ws2812.c |
| 34 | QSPI at clk/2: in a write burst the first nibble of every later word changed on SCLK's rising edge, the one the part samples (the Arty's PSRAM at clk/2: the cache on failed); and a late read capture, 0x1E [14:13] per select: a read bit taken again on the following falling edge, for the round trip through the pads and the part | `lisa_qqspi.v` S6, rd_late / late_pend, `debug_regs.v` 0x1E, `tt_um_pettit_lisa.v` | done: tb.v SPI_DOUT_DLY / SPI_TCO, SPI_REG=0x6010 |
| 35 | An extension: the WS2812B driver's DMA - a frame from a PSRAM buffer (BASE / LEN in the output flops) through the TTLC's fetch, two pixels a group, the data cache flushed first, FRAME / REPEAT; and the data cache served a core access during a flush from the flush's line | `lisa_ws2812.v`, `ttlc_fetch.v` ws_*, `tt_um_pettit_lisa.v` ttlc_addr / ce / flush, `data_cache8.v` cache_hit | done: test/progs/wsdma.c (make WSDMA=1), sdcc_test/test_wsdma.c, hw_wsdma.c |
| 36 | An extension: a 32-bit cycle counter, a watchdog (resets the core and the peripherals, WDRST flag) and a PDM (first-order sigma-delta) mode for each of Timer 3's channels in place of its input capture, on the PWM pin - an 8-bit DAC through an RC filter | `lisa_cyccnt.v`, `lisa_wdt.v`, `lisa_timer3.v` IE [6:5], `lisa_periph.v` 0x48-0x4F, `tt_um_pettit_lisa.v` the core's and the peripherals' resets | done: test/progs/misc36.c (make MISC36=1), sdcc_test/test_misc36.c |
| 37 | An option: DDR instruction reads - with 0x17 [6] the flash's instruction bursts and the debugger's single-word reads are DTR Fast Read Quad I/O (EDh, the W25Q128JV-DTR), a word every 4 clocks at clk/2 instead of 10; the read data through a capture pipeline whose point (0x17 [11:9], half clocks) the host finds by sweeping it; 0x17 [8] puts the SDR bursts through it too (8 clocks a word); off at reset | `lisa_qqspi.v` S13_RUN, dtr / run, cap_pipe, sclk_n / sio_neg, `debug_regs.v` 0x17 [15:6] | done: test/test.py test_ddr_sweep (make DDRSWEEP=1), DDR_CAP= / SEAMLESS= / DDR_TOGGLE= for any program |
| 38 | Timing: the slow corner's worst paths (rc23 -8.7 ns): lda (ix++)'s kfetch -> the fetch address -> the window lookup -> inst -> the data address adders -> d_addr_good -> d_ok -> every register; and inst_r -> facc timed as one clock.  What an instruction does in its exec state reads inst_r (the window lookup stops at the decode flops), kfetch its own flop, 0x2B / 0x2E's TTLC flag bits registered (FLAG_O is a falling-edge flop), and lisa.sdc's missing multicycle sources (inst_r, the BF16 flags, facc and the f registers) | `lisa_core.v` inst_r, kfetch_q; `lisa_spi.v` scan_req_r; `lisa_periph.v` ttlc_wait_r; `lisa.sdc` | done: every suite as before, the kfetch_q check in simulation; rc29 -0.44 ns (1 endpoint, a real path) at the slow max corner against rc23's -8.74 (183), nom_ss / min_ss clean |

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
  (`ttlc_exec`, from `tt_um_pettit_lisa.v`), then clears run; a run or step written
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

**Done.** An 8-byte FIFO in `lisa_rx8n.v` (both UARTs).  Its overrun flag
(a byte arrived with the FIFO full; it stays set until the FIFO has been
read empty) was left unconnected until 2026-10-18 (Ken, with the
interrupt-driven receiver in mind: a lost byte was invisible): it is bit 2
of the UART status 0x11 (the console UART's receiver sits in
`debug_ctrl.v`, shared with the debugger) and bit 3 of UART2's 0x13
(`lisa_uart.v`, `lisa_periph.v`).  The UART interrupt is an edge of
"data available" (and of "TX empty" when enabled), so a receive handler
acknowledges first and then drains while bit 0 is set.  Test:
`make OVERRUN=1` (test/progs/uartov.c: twelve bytes into the FIFO while
the program looks away, the flag set, eight bytes out, the flag gone,
the echo after).  Hardened in rc7.

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

## 19. The TTLC program format: 12-bit slots

**Symptom.** A TTLC instruction needs its 4-bit opcode and an 8-bit I/O
address (the I/O space is 139 bits); TT07 spent a 16-bit word on each, the
upper 12 bits a jump address that only `jmp` uses - the 6x2 elevator (847
lines) has no `jmp` at all - behind a four-line instruction cache.

**RTL** (2026-10-17, Ken's design): `src/ttlc_fetch.v` replaces
`ttlc_inst_cache.v` and the PC / stack logic of `tt_um_pettit_lisa.v`.
Instructions are 12-bit slots, four to a group of three words; `jmp` takes
two slots, the second its 12-bit target group; the PC is {group, slot} (14
bits, as are the stack's entries, with a valid bit); two groups are
buffered, the executing one and the next (prefetched, or the jump's
target), each one QSPI burst of three words - about the old cache's flops,
a quarter less flash and a quarter fewer bursts per instruction.  The
sequencer takes two clocks an instruction and moves the PC once, at the
clock the core executes: the target, the return, the nopf's 0, or on by
one slot (two over a skipped `jmp`).  The debugger's TTLC PC (0x41) is 14
bits, its breakpoints (0x48-0x4a) {valid, pc[13:0]} at bit 14, per
instruction.  `test/progs/ttlc/mc14500_as.py` assembles the format (labels
on group boundaries, pairs inside a group, nop = `or 137`, a `skz` kept
beside what it skips; `--format words` is TT07's).

**Found on the way.** The old RTL's `jmp` never worked: the core's JMP
level stays up until it latches the next instruction, and item 13's
`mc14500_pcen` let it reload the PC and push the stack on each of three
clocks, the third from an instruction word the cache had zeroed on the
target's miss (a trace of a jmp/rtn program under icarus, test_ttlc_trace).
Nothing had run one: the elevator and the loopback have no `jmp`.

**Test.** test_ttlc (the loopback, 98 instructions in 25 groups),
test_ttlc_debug (the breakpoint at 5 = group 1 slot 1, the step, the wrap
on nopf) and test_ttlc_jump (the loopback through two subroutines, a `skz`
over a `jmp`, `nopf`; its `done` label on group 8 so that a skip advancing
one slot would execute the target slot as `sto 0`): all pass on the chip
testbench; the LISA default tests unchanged.

## 20. The autobaud's 32-clock steps

**Symptom.** The debug UART's rate must have a bit that is a multiple of
32 clocks: `debug_autobaud.v` kept the measured pulse width over 32 and
`debug_brg.v` counted the 16x reference in units of 32 clocks (a bit is 32
x (divider + 1)).  At 50 MHz neither 115200 (434 clocks) nor 460800 (108.5)
locks; the FPGA build needed 156250 (320) and 40 MHz 125000.  Found on the
Arty, 2026-10-17; Ken: "improve the autobaud so it doesn't count in
multiples of 32 clocks".

**RTL.** `debug_autobaud.v` hands the BRG the pulse width in clocks (14
bits; the three latest pulses must agree within two clocks and be 32 or
more).  `debug_brg.v` keeps the period in clocks and toggles the reference
32 times a period from an accumulator (32 per clock, a toggle when it
reaches the period, the remainder kept), so the 16 rising edges a bit the
receiver and transmitter count land within a clock of where they belong,
whatever the period.  The divider pins keep their meaning (32 x (b_div +
1)); the reset default is 416 clocks as before.  `brg_div` is 14 bits
through `debug_ctrl.v` and `tt_um_pettit_lisa.v`.

**Test.** test_autobaud (test/test.py): the testbench UART's bit set to
288, 300, 434, 109, 57 and 32 clocks in turn (tb.v's `bitclks`), the chip
with ui_in[7] low trains on the LF and answers `v` and a register write
at each.  On the Arty at 50 MHz: hello with the cache on at 115200,
156250, 460800 and 921600, the TTLC loopback at 460800.

## 21. Quad reads: the flash's mode bits floated

**Symptom.** A quad read of the flash (`EB`, the fast read quad I/O) did
not work on the Arty: the debug port's read-back of a freshly written
image came back 31 or 60 words wrong of 64 whatever the dummy count
(2026-10-18, when quad on both selects became the FPGA's default; the
PSRAM had run quad from the start).  `lisa_qqspi.v` sends the command on
one line, the address and the data on four, and floats the bus for the
dummy clocks - but a flash samples its mode bits M7-0 from the first two
of those, and M5:4 = 1,0 (0xA5 on a Macronix part) switches it into
continuous-read mode, where every later command byte is taken as address
bits.  With nothing driving the lines the mode byte is whatever they
float to; TT07's demo board happened to work.  The chip has no pull-ups,
so a pull-up on the FPGA would only have hidden it (Ken: fix it in the
RTL).  tinyQV, on the same Pmod, never floats them: it drives 0xA for the
two clocks to live in continuous-read mode and skips the state for its
PSRAMs.

**RTL.** `lisa_qqspi.v`: a quad read of a flash select goes through a
new state after the address, S12_MODE, which drives all four lines 1 for
two clocks (8 bits in quad through the shifter: 0xFF is nothing to any
part), then S5_WAIT floats the rest of the dummy clocks, which the count
still includes (6 = 2 + 4 for the W25Q128JV); a RAM select gets all its
wait cycles floating as before.

**Test.** The chip testbenches (quad flash and PSRAM models; the flash
model enters its XIP mode on 0xA5 only) unchanged, the cache suite
through the quad PSRAM model included; on the Arty the debug port reads
the image back through quad with no mismatch, hello, test_core and the
TTLC loopback run quad on both selects, and lisa_monitor runs 3 to 5
times faster than from single-SPI flash (fpga/README.md).  rc4's GDS
predates this; rc5 and rc6 (promoted) have it.

## 22. Bank registers: 2 MB of code, 256 KB of data

**Why.** Not a silicon issue: an extension.  Ken (2026-10-18) wanted more
code and data than 32K words / 32 KB without leaving the 16-bit opcode, the
PIC18's banking rather than a wider PC (the cond tag in bit 15 of a saved
return address leaves no room for one, and widening PC, IX, SP, RA, IA and
every stack frame would stop being "little").  Four-bit banks (Ken: "large
enough to run some pretty decent size applications"), then a 6-bit code
bank the same day (Ken: 16 x 16K words is only 256K words of code; the
instruction stream holds one window, no tagged lines, so the two bits are
cheap): 1M words (2 MB) of code, 256 KB of data.

**ISA** (`lisa_isa.md`, "Bank registers").  Three registers in the
peripheral space (the code bank 6 bits, the data and stack banks 4), reset 1 = the TT07 layout: `CB` 0x15, the code bank of a
fetch above word 0x4000 (physical word `{CB, PC[13:0]}`); `DB` 0x16, the
data bank of an IX-relative or debugger access above 0x4000; `SB` 0x17, the
stack bank of an SP-relative access above 0x4000.  Below 0x4000 is bank 0,
common; direct `[abs9]` accesses never leave it.  The stack bank is its own
register (Ken: with one data bank an RTOS could not give each task a stack
of its own - NuttX-style task stacks would all have to fit in one window -
and banking the stack through the data bank would let a far pointer move
the stack).  No shadows on an interrupt: an ISR runs under the interrupted
code's banks, so handlers live in the lower 16K; a task switch is SP, SB,
CB, DB.

**RTL.** `lisa_periph.v`: the registers, read back with the unused bits zero.
`lisa_core.v`: `d_sp`, the data address is SP-relative (`sp_sum` or `sp_addr`
in the `d_addr` mux).  `tt_um_pettit_lisa.v`: `core_i_paddr` = `{CB or 0,
PC[13:0]}` into the instruction stream, `d_bank_c` = 0 / `SB` / `DB`
registered beside `d_addr_r` (and in `d_addr_good`), 20-bit words to the
LISA1 flash address and 18-bit bytes to the LISA2 address.
`inst_stream.v`: the window's head and the burst address 20 bits wide; a
switch is a mismatch on the next fetch into the upper half, no flush.
`data_cache8.v`: the bank in each line's tag (4 flops a line, 0 unless the
32K map, `cache_map_sel` 3), the line index bit "bank != 0" so that bank 0
through the window shares the lower half's lines, the fill and write-back
address from the tag - a dirty line goes back to its own bank.  A switch
flushes nothing.  Also `test/psram.v` holds 256 KB now.

**Test.** `test/progs/bank.c` (`make BANK=1`, the cache on: the banks are
PSRAM; the image bank_test.hex puts `ldi #bank; ret` at word 0x4000 of
banks 1, 2, 3 = flash bytes 0x8000, 0x10000, 0x18000): the reset values and
width, calls into the three code banks, one address in three data banks
through the cache, bank 0 as the lower half, evictions between banks 2 and
3, the stack in bank 2 (pushed there, read back through the data bank, bank
1 untouched), and the write right before the access it applies to.  The
default suite and the core testbench unchanged.  `lisa_sim --rev2` models
the banks (code_pa / data_pa, 18-bit memories; mem / dis through the
bank); `sdcc -mlisa` has `__banked` functions and `#pragma bank n` through
one common trampoline, `___sdcc_bcall` (the bank byte pushed by the caller,
the callee's frame 3 bytes deeper, 3-byte banked function pointers, the
linker mapping every code word >= 0x4000 into the window; README-lisa.md
"Code banks"); `lisa-tools/sdcc_test/test_bank` (banks 2 and 3) passes on
lisa_sim, on this testbench and on the Arty (the bitstream with the banks
closes at 50 MHz, setup +0.25 ns).  Data banks followed (sdcc-lisa
85513a3): SDCC named address spaces with a switch function writing the
data bank, the linker checking every bank area's placement and that the
common code and ordinary data stay in the lower halves;
sdcc_test/test_dbank passes on lisa_sim and this testbench.  The debugger
tools followed (lisa-tools 769bb03): lisa_sim, lisa_ide and lisa_pydb work
in physical code addresses, read the banks through the debug port (data
address 0x8015-0x8017), pass over a breakpoint hit in another bank and
backtrace through ___sdcc_bcall - checked on the Arty.  Not done: a TTLC program convention above the
code banks (arty_ttlc.py puts it at byte 0x10000 = code bank 2).

## 23. A transmit pops the receive FIFO

**Symptom.** Found 2026-10-18 by the overrun test (item 14): the program
let twelve bytes queue, printed its first result line and then drained the
receiver - and got one byte, the ninth.  The core's `d_rd` is a
peripheral-access strobe, high in the exec state of every `lda`, `sta` and
`swapi` to the peripheral space (`lisa_core.v`: `d_periph & cond[0] &
exec_state`), and `lisa_periph.v` popped the receive FIFO on `d_rd` at
address 0x10: each character written to the UART took a queued received
byte with it - eight characters of "ok 0001", eight bytes gone.  TT07 has
the same decode; its one-byte receiver hid it, since an echo loop has read
the byte before it writes.  With the 8-byte FIFO it is a data-loss bug
whenever a program transmits while input is queued (a monitor echoing a
pasted line).  The same strobe cleared a timer's rollover on a write to its
control register, and `uart2_brg_wr` fired on ANY access to 0x14, the UART
interrupt enables, so reading or writing them rewrote UART2's baud divisor
with whatever was on the data bus.

**RTL.** `lisa_core.v`: `d_rd` is the read strobe, `lda` and `swapi` only
(`& ~op_sta_r`); a store's exec clock no longer pulses it.  Masking with
`d_we` in the peripheral block cannot work - the core's `d_we` is a
registered signal, a clock behind the exec clock that pulsed `d_rd`, so
the pop had already happened.  The peripheral decode is unchanged (the
receive FIFO pops and the timers' rollover clears on `d_rd`).  UART2's
baud divisor has its own register, 0x1E (write; a bit is 32 x (d + 1)
clocks, as the debug BRG), and 0x14 is only the interrupt enables.  The
console UART's receive path holds one byte more than the FIFO (the debug
controller's hand-over register): nine bytes queue before the overrun
flag.

**Test.** `make OVERRUN=1` (test/progs/uartov.c; the report lines are
printed before the drain, so the test fails on the old decode); the
default suite.  lisa_sim had no such pop (its write path never read).

## 24. ldirq loads nothing

**Symptom.** Found 2026-10-18 with NuttX on the Verilator testbench and
the Arty: the kernel ran to its first timer interrupt exactly as lisa_sim
(69840 instructions, every register the same), the handler's path was the
same, and after `rets` it came back with `amode` 0 - from then on every
`shl`/`shr` of the compiler's code shifted 0 in instead of C, and the
shell never started.  NuttX's restore does what a context switch has to:
`ldirq` at the entry saves the byte of shadows, `stirq` at the exit writes
it back and `rets` takes the live flags and `amode` from the shadows (item
6).  The byte it saved was 0: `ldirq` had not loaded A.  `op_ld_misc_r`
(the 101000.. misc loads) covers 0xA120 and comes first in the
`acc_load_val` case; its `acc_misc` block has no `ldirq` entry, so the
separate `op_ldirq_r` item below it was never reached.  A plain `ldirq`
anywhere returned A unchanged; nothing but a `ldirq`/`stirq` round trip
noticed, and no test made one (sdcc's handlers leave the shadows to the
hardware).

**RTL.** `lisa_core.v`: the `ldirq` value in the `acc_misc` case,
`{amode_isr, signed_inv_live_isr, cflag_save_isr, signed_inv_isr,
zflag_isr, cflag_isr}`, the byte `stirq` takes back.  `lisa_sim --rev2`
(and `--fixed-irq`) models the byte and `ldamode`; `sdaslisa` assembles
`ldamode`.

**Test.** `sdcc_test/test_ldirq.c` (`--rev2`): a handler that does the
round trip with A set to 0x5A first; main checks the byte it saw (amode 1
in bits 7:5), `ldamode` after the interrupt (ie 1, amode 1) and a shift
through C.  On lisa_sim --rev2, the testbench (`run_suite.sh chip CACHE=1
REV2=1`) and the Arty.  Hardened in rc10.

## 25. The UART interrupt enables cannot be written

**Symptom.** Found 2026-10-18 with NuttX on the Arty and the Verilator
testbench: the shell prints its prompt and never sees a keystroke.  The
testbench's trace (tb.v's Q lines) shows the driver writing 1 to 0x14
once at boot and every later read-modify-write of the register starting
from 0: `lisa_periph.v` declares `uart_rx_ie` and `uart_tx_ie`, resets
them, uses them in the edge detectors of item 14's interrupt bit and reads
them back at 0x14 - and never assigns them.  TT07's lisa_periph.v is the
same, so no UART interrupt has ever fired on either chip; nothing noticed
because every program so far polled the UART (sdcc's suites, lisa_monitor,
the TTLC tools), and item 23 found only the side effect an access to 0x14
had on UART2's baud divisor.

**RTL.** `lisa_periph.v`: a write to 0x14 loads the four enables (bit 0
UART1 receive, 1 UART1 transmit, 2 / 3 UART2).  And the UART requests are
levels (Ken's decision, 2026-10-18): INT_STATUS bit 2 (3 for UART2) is "a
byte waits and the receive interrupt is enabled, or the transmitter is
empty and its interrupt is enabled", for as long as that holds - a byte
already waiting when the enable is set interrupts at once, a second byte
queued behind an unread one keeps the request up, the handler ends it by
draining the FIFO, writing the next byte or dropping the enable, and a 1
written to the bit in INT_STATUS does nothing.  Until then the rising edge
of the condition was latched and acknowledged like an event, so both of
those cases lost the interrupt for good.  The other sources are instants
and stay latched until acknowledged: the timers' rollovers, the port's
edges, the TTLC's toggle (the port's mode 1 is a level of the pin itself,
the I2C request the I2C core's own).  `lisa_sim --rev2` models the same
(and TT07's unwritable enables: no UART interrupt there).

**Test.** `sdcc_test/test_uartirq.c` (`--rev2`): the enables written and
read back; the transmit request up as soon as its enable is set with the
transmitter empty, unchanged by an acknowledge, gone when the handler drops
the enable, and raised again when a byte on its way out has left; two typed
bytes (`lisa_sim --send Hi --send-at <cycles>`; the testbench `SEND=Hi
SEND_DELAY=<clocks>`, in run_suite's list; the Arty with arty_run's SEND)
waited for with the interrupt off, then the enable set: the request up at
once, the handler takes both, the request gone.  `lisa_sim` transmits a
byte in `char_cycles` (100 by default) so the transmitter is busy for a
while, as the chip's is.  Hardened in rc10.

## 26. lda (ix++): constants packed, in any bank

**Why.** NuttX's image (2026-10-18) filled the common area - the lower 16K
words, visible from every bank - to 29.3 of 32 KB, 16.5 KB of it CONST:
a constant byte was an `ldi #b; ret` pair read by `call ix`, four bytes of
flash per byte, and it had to be below 0x4000 because the reader did not
switch banks.  Ken's idea: read the code memory as data.

**RTL.** `lda (ix++)`, 0xA14C (the misc slot after `ldamode`): from its
exec state the core asks the instruction bus for the word at IX[14:1]
with `i_kfetch` up, which `tt_um_pettit_lisa.v` sends to bank KB (the constant
bank register, `lisa_periph.v` 0x1F, 6 bits, reset 0 = the lower half);
the exec state waits for the stream (`k_ok` in `d_ok`), A takes the byte
IX[0] selects, Z follows it, IX gains one with its condition bit kept.
KB does not carry when IX wraps: the compiler keeps a constant inside its
bank (32 KB of byte addresses).  KB is set once per image, so no
interrupt frame carries it and pointers stay two bytes.  The stream
treats the read as any fetch: a burst at the constant, then one back at
the PC - no slower than the call and return it replaces; a second window
for constants would make a string stream (open).  `lisa_sim --rev2`
models it; `sdaslisa` assembles the form.

**Test.** `sdcc_test/test_ldk.c` (`--rev2`): KB written and read back,
the words of a function in the lower half read byte by byte (the low
byte first, Z on a zero byte, IX + 1 each), then the words of a function
placed in bank 2 with KB = 2; 22 checks.  The packed CONST area, the
reader `__gptrget` and NuttX's layout follow in the toolchain (lisa-tools).
Hardened in rc10.

## 27. The divider's second result, and a chained step

**Why.** NuttX's printf spent 64% of an `xd` in SDCC's 64-bit division:
a 64-step bit-serial C loop of 20-23K instructions, 3 ms at 50 MHz
(the 32-bit routines run on the hardware divider, divul.s, in 75-500).
A 16-bit divider on its own cannot continue a long division: the
remainder of one step has to come back as the high part of the next
dividend.  Ken asked (2026-10-19) whether the divider could be extended.

**RTL.** `lisa_div.v` is a restoring divider now: one 17-bit
subtractor, 16 clocks for a division and 8 for a chained step (it was
repeated subtraction in steps of the divisor shifted by 10, 7, 4 and 0
bits - four compare-and-subtract pairs, 10 to 95 clocks).  The
dividend's magnitude shifts out of `result` (RA) into the remainder `b`
(IX) while the quotient shifts into `result`.  Both results come out:
`div` leaves the quotient in RA (its low byte in A) and the remainder in
IX, `rem` the other way round - TT07 and rc10 cleared IX at the end.
The divisor's magnitude stays latched in `a`, and `divc` (0xA174, the
misc slot after `lddiv`; one word, waiting for the divider as `div 1`
does) divides {IX, A} by it: the quotient byte to A and RA, the
remainder to IX.  One `divc` per byte, most significant first, after a
`div` by the divisor (of 0, or of the top byte), is a long division of
any width by a 16-bit divisor with the remainder carried in IX - a
64-bit value by 10 in some 40 instructions.  IX must be below the
divisor at a `divc` (it is after a division by the same one); the step
is unsigned.  The latched divisor is state an interrupt handler that
divides would replace: a chain runs with interrupts off, or the
handlers do not divide.  Signed mode (amode[1]) follows C now: the
remainder takes the dividend's sign (the earlier divider negated it by
the divisor's; nothing compiled uses signed mode).  By zero (the
quotient all ones, the remainder the dividend) and -32768 / -1 as
before.  Z is untouched by any division, as it always was (lisa_sim had
set it).  `lisa_sim --rev2` replays the divider's loop bit for bit;
`sdaslisa` assembles `divc`.

**Test.** `sdcc_test/test_divc.c` (`--rev2`, the stack at 0x7fff for
the library's 64-bit frames: the testbench's CACHE=1 list): both
results of div and rem (bit 15 of either, by zero, by one), five signed
cases, 0x12345678 / 1000 by bytes, single steps with a remainder carried
in (after a div and after a rem), and nine 64-bit chains against the C
library's division; 26 checks.  The library's 64-bit routines on the
step are toolchain work (lisa-tools).  Hardened in rc11.

## 28. The data map: a common 8K, a data window of 8K granules, a stack window

**Why.** Not a silicon issue: an extension of item 22.  Ken (2026-10-19),
after NuttX's task banks on item 22's map: "any task only gets a max 16KB
of its own data counting heap plus stack", and the proposal that the bank
be chosen by the address rather than by the form of the access, so that a
pointer means one thing however it is dereferenced and `DB` and `SB` may
differ.  Item 22's map chose `SB` for SP-relative accesses and `DB` for
the rest, so a pointer to a stack object was right only while `DB == SB`:
each task got one 16K bank for stack and heap together, and the kernel
reached another task's bank only through a trampoline on a scratch stack
in that bank.  Ken's first form (two 16K windows, the kernel's data swapped
in by a "kernel bit") needs a copy-in / copy-out layer that flat NuttX has
nowhere, so the data space keeps a region the kernel can always see,
shrunk to what it uses (its statics are 1.6 KB, its heap a few KB): the
24K mode with an 8K kernel and a 5-bit `DB` choosing an 8K granule.

**ISA** (`lisa_isa.md`, "Bank registers").  Three regions by address
alone: below 0x2000 the common 8K (physical 0); 0x2000-0x3FFF the data
window on one of 32 granules of 8K, `DB` `[p:0x16]` now 5 bits (physical
`{DB, addr[12:0]}`); 0x4000-0x7FFF the stack window on one of 16 banks of
16K, `SB` `[p:0x17]` (physical `{SB, addr[13:0]}`; bank n is granules 2n
and 2n+1).  Reset 1 = physical 0-32K flat, the TT07 layout, so every image
that never writes the registers runs unchanged; granule 0 through the data
window is the common 8K, bank 0 through the stack window the common 8K and
granule 1.  The code space is as in item 22.  A task can have a granule
for its heap and a stack in a bank shared with other stacks, or a bank of
its own and then 24K less the stack as one contiguous heap; a stack in the
data window works too (a thread's, from its group's heap).

**RTL.** `tt_um_pettit_lisa.v`: `d_page_c[4:0]` = physical bits 17:13 of the
access (`{SB, addr[13]}`, `DB`, or 0 by address bits 14 and 13); `d_bank_c`
is its upper four bits and `d_a13_c` bit 13, registered beside `d_addr_r`
and in `d_addr_good`; the core's `d_sp` is no longer used.
`lisa_periph.v`: `data_bank` 5 bits (reset 1, read back with the high
bits zero).  `data_cache8.v`: the new input `d_a13`; the line tag is the
physical bits 13:6 (`tag_addr`) instead of the window address's, in the
compares and the tag stores; the bank bits, the index bit "bank != 0" and
the fill / write-back address are unchanged.  Nothing in `lisa_core.v`.

**The cache's line index** (the same day, after NuttX on the Arty).
Item 22 indexed the eight lines by "a bank other than 0" of the physical
address, which on this map put the data window's granules on the stack's
side: four direct-mapped lines for a task's stack and heap together, and
a loop over both thrashed (a probe, `lisa-tools/sdcc_test/test_bankspeed.c`:
108 ms for 12K accesses in the data window against 49 ms in the common
8K, 2.2x, on the chip bench and the Arty alike).  The index is address
bit 14 now, Ken's intent for the map - the stack window has lines 4-7,
the common 8K and the data window lines 0-3 - and the data window runs at
the common 8K's speed (49 ms).  The tags stay physical, so the only
consequence is for a byte reached through both windows at once (a stack
bank's half as a granule, bank 0 through the stack window): the two
windows cache it in different lines, and a write through one is seen
through the other once its dirty line is written back; granule 0 through
the data window is the common 8K in the same half, one place.  bank.c's
cross-window checks evict the lines first.

**Test.** `test/progs/bank.c` rewritten (`make BANK=1`, 35 checks, passes
on Verilator): the widths (5, 4, 6 bits), the code banks as before, one
address in three granules through the cache and the write right before
the access, granule 0 as the common 8K, granule 1 as bank 0's upper half
through the stack window, granule 2 as bank 1's lower half (one byte at
0x3000 under `DB` 2 and at 0x5000 under `SB` 1: one cache line), an IX
access above 0x4000 going to the stack bank whatever `DB`, evictions
between granules 4 and 5 and the same bytes seen through bank 2, pushes
with SP in the stack window landing in `SB`, pushes with SP in the data
window landing in `DB`.  Toolchain: `lisa_sim --rev2` maps the three
regions (`LisaCore::data_pa`, the 5-bit register); `sdcc -mlisa`'s linker
places a `DBANKn` area in 0x2000-0x3FFF and wants ordinary data below
0x2000 (README-lisa.md "Data banks"); `sdcc_test/test_dbank` is linked at
0x2000; `lisa_pydb` masks the data bank to 5 bits.  NuttX (branch lisa):
the task banks on this map - each task a granule for its heap, a stack
in a shared bank or (a stack of 4 KB or more) a bank of its own with the
heap up to the stack, the kernel's visits on a scratch stack in the
common 8K, `free` over the 31 granules; verified on lisa_sim, the chip
bench and the Arty (bitstream slack -2.83 ns).  The Arty hunt for lost
typed input found the shell starved by same-priority tasks and its
63-byte receive ring overflowing while `ps` took a second per task: nsh
runs at 110 above the applications now, with a 256-byte ring (nuttx
d9b13ebb).  It also found the Arty tools still loading the QSPI timing
of the emulated-RAM days, 0x1e = 0x08d3 (SCLK clk/8, a 13-clock gap
between transactions, mode 1 on the flash); the Pmod's flash and PSRAM
run at clk/4 with a 1-clock gap (`SPI=0x0811`, twice the memory
throughput; clk/2 fails in either mode), the testbench at clk/2.

## 29. A SPI master on its own pins

**Why.** Not a silicon issue: an extension (Ken, 2026-10-21).  The core
needs a flash (or an SD card) it can write for a file system.  A fifth
client on the QSPI arbiter was looked at first and set aside: a transaction
the core feeds or drains word by word holds the bus its own next
instruction fetch waits for, and a flash busy with a program or erase
answers no fetch from it.  A small SPI master on pins of its own has
neither problem: the core polls a register, and the bus it fetches from is
never involved.

**Registers** (`src/lisa_spi.v`; `lisa_periph.v` 0x28-0x2B).

| Address | Register | |
|---|---|---|
| 0x28 | DATA | a write sends the byte (ignored while BUSY); a read returns the byte received and clears DONE |
| 0x29 | CTRL | [0] CS0, [1] CS1 asserted (the pins are active low), [2] CPOL, [3] CPHA, [4] CLAIM the TTLC's pins, [6:5] MISO from ui_in[0], [1], [2] or [7], [7] IE |
| 0x2A | DIV | half an SCLK period is DIV + 1 clocks (reset 3): core/2 to core/512, about 98 kHz at 50 MHz for an SD card's initialization |
| 0x2B | STATUS | [0] BUSY (a byte sending, or waiting for the pins), [1] DONE, [2] OWNED, [3] TTLC_WAIT |

DONE with IE is interrupt source 7 (INT_STATUS bit 7, vector 8), a level
like the UARTs': reading or writing DATA ends it.  A byte takes
16 x (DIV + 1) clocks plus two.  CPHA 0 presents bit 7 before the first
edge, samples MISO on the leading edges and shifts on the trailing ones;
CPHA 1 shifts on the leading edges after the first and samples on the
trailing ones.  MISO is sampled as the edge is made, half a period after
the device's shift; ui_in[7] is the autobaud's baud_set at reset, so a
device holding MISO high there sets the baud divider: prefer ui_in[0..2].

**Pins** (`lisa_io_mux.v`; the output mux register 0x1b per pin).

| Pin | mux 0 (default) | mux 2 (periph_sel1) | mux 3 (periph_sel2, the TTLC) |
|---|---|---|---|
| uo[0] | | | MOSI while OWNED, else the 595 chain 0's data |
| uo[1] | | | CS0 while OWNED, else chain 1's data |
| uo[2] | | | CS1 while OWNED, else chain 2's data |
| uo[3] | | CS0 | |
| uo[5] | | SCLK | |
| uo[6] | | MOSI | |
| uo[7] | CS1 | | SCLK |

uo[7] under mux 0 was 0; it is CS1 now, high at reset.  On the
TTLC's pins the 595 chains keep their own shift clock (uo[6]) and latch
(uo[5]), so the SPI's clock never reaches them and they need nothing
external; only their data lines are shared.

**The interlock** (`tt_um_pettit_lisa.v`).  A scan drives uo[0..2] with the
outputs' bits and clocks them into the 595s, so the two cannot overlap:
- CLAIM asks for the pins; OWNED is granted with no scan running
  (io_busy) or requested (FLAG_O, or one waiting), and kept until CLAIM is
  cleared and the byte in flight is out.  A byte written while CLAIM is set
  and not yet granted waits for the grant.
- A scan the TTLC requests while the pins are owned waits:
  `ttlc_scan_pend` keeps the request (FLAG_O is a one-clock pulse) and
  holds the ICU (`mc14500_run`); the scan starts the clock the pins come
  back.  TTLC_WAIT shows it, so a driver can release the pins between
  transactions; holding them stretches the PLC's loop by that long.
- The CS lines carry the TTLC's data while not owned, so they can select a
  device then, with no clock: harmless to a flash or an SD card, not to a
  part that acts on a select's falling edge.  The SCLK pin of mode 3 moves
  only from the clock after the grant to the release (`sclk_m3`), so a
  CPOL written before the grant does not make an edge under such a select.
  Claim with the selects deasserted, assert them once OWNED.

**Test.** `test/progs/spi.c` on the chip bench (`make SPIM=1`) against two
devices in `tb.v` (`spi_dev`: device 0 CPHA 0 answers each byte with the
complement of the one before, device 1 CPHA 1 with it plus one; CPOL from
the clock's level at the select).  test_spi: the mux-2 pins, the
dividers 0, 1 and 5, both polarities and phases, the readback, DONE and its
request.  test_spi_ttlc: the same on the TTLC's pins with the loopback
running, then 24 more transactions; the 48 outputs never leave the inputs,
no TTLC shift clock falls inside a transaction (`spi_collide`), the program
sees TTLC_WAIT (in 31 of its 61 transactions), and the loopback follows new
inputs after.  With the interlock taken out the test fails (1287 shift
clocks inside transactions).  Verilator and icarus.
`lisa-tools/lisa_sim` (`spi.h`): the registers, the byte time, the
interrupt and a SPI NOR flash on CS0 or CS1 (`--spi-flash FILE[,SIZE]`,
the W25Q128JV's commands, written back at exit; the TTLC's pins granted at
once, there is no TTLC); `sdcc_test/test_spiflash.c` (make check REV3=1):
the JEDEC ID, the write enable, a 4K erase, programs that wrap in their
page, read and fast read.

**Cost.** About 47 flops and the muxes (rc15's area is 70% of the tile).
Hardened as rc16 (2026-10-22, the hardening section); the Arty bitstream
rebuilt 2026-10-23, an SST25VF064C on the mux-2 pins read and written there
(lisa-tools sdcc_test/hw_spiflash*.c, NuttX arty:smartfs).

## 30. The TTLC's I/O from the core

**Why.** Not a silicon issue: an extension (Ken, 2026-10-23).  The core
could see the TTLC only through the 8-bit mailbox (port D = the storage's
low byte, port E = the ICU's port_in).  With the I/O vector readable the
core can watch the PLC's inputs, outputs and storage while it runs; with
the outputs writable and a scan it can start, the 74HC595 / 74HC165
chains are the core's own 48 outputs and 48 inputs when the ICU is not
running (its reset state: ttlc_run is 0).

**Registers** (`src/lisa_ttlcio.v`; `lisa_periph.v` 0x2C-0x2E).

| Address | Register | |
|---|---|---|
| 0x2C | TIDX | the byte, 0-17 (an index past 17 reads 0) |
| 0x2D | TDATA | read: byte TIDX of the vector; write: byte TIDX of the outputs (0-5) or the storage (12-15), others ignored; a read or a write moves TIDX on (17 wraps to 0) |
| 0x2E | TCTRL | write: [0] START a scan (and clear DONE); read: [0] BUSY, [1] DONE (a scan has ended since the last read, with no START still waiting; the read clears it), [2] PEND (a START not yet taken), [3] TTLC_WAIT (the ICU holds at a scan the claim keeps back), [4] OWNED |

The bytes are the ICU's addresses eight at a time (`ttlc_io.v`
read_values): 0-5 the outputs (address 0-47), 6-11 the inputs (48-95),
12-15 the storage (96-127; byte 12 is port D), 16 port_in (port E), 17
{.., 1, 0, RR}.  Six reads and the inputs are the core's; six writes and a
START and the outputs are on the chains.

**Reading never disturbs the ICU**: a second read port on the vector
(an 8-bit 18:1 mux - the ICU's 139:1 bit mux stays its own).  The inputs
change only at a scan's end, so DONE tells a read of the six input bytes
that spans one; the outputs and storage change as the ICU writes them.

**Writing.** A byte written in the clock the ICU writes one of its bits:
the ICU's bit wins, the other seven are the core's.

**Scans.** START is kept (PEND) until shift_reg_io takes it (idle), so a
START during a scan runs a fresh one after it; it also waits for the SPI
master's byte in flight.  `ttlc_io_start` = the TTLC's own request (FLAG_O,
or one waiting) while the pins are not owned, or the core's START.

**Atomic updates with the ICU running** (Ken's design: the SPI master's
claim, item 29, is the halt): set CLAIM (0x29 bit 4) and wait for OWNED -
the ICU's own scans now wait, so it stops at its next one (TTLC_WAIT, if
it is running at all) - write the outputs, START (allowed while the claim
is held: the core holds it), read the inputs, clear CLAIM.  For the scan
the mode-3 data pins uo[0..2] go back to the chains (`lisa_io_mux.v` gets
OWNED only outside a scan), and the SPI master starts no byte on the
claimed pins while a scan runs (`lisa_spi.v` go), so the two never
overlap.  After the release the ICU's held scan runs: with the outputs
the ICU left (the core's, until the ICU's loop writes its own).

**Test.** `test/progs/ttlcio.c` on the chip bench (`make TTLCIO=1`, mux
mode 3, the inputs 0x0123456789ab on the 165 chains).  test_ttlcio, the
ICU halted: the index's auto-increment and wrap, byte 17's constants,
port_in at 16, outputs and storage written and read back, the storage's
low byte on port D, the inputs not writable, a scan (DONE, cleared by the
read), the inputs it captured, and a second set of outputs found on the
595 chains after the run.  test_ttlcio_run, the ICU running its loopback:
two of its scans watched, the inputs and the copied outputs read, then
the claim, TTLC_WAIT, the core's outputs and its own scan while held, the
outputs still the core's (the ICU waited), the release, and the loopback
copying the inputs again; whenever the chains' outputs left the inputs
they were the core's (`tb.v` ttlc_watch / ttlc_match: 74570 of 74570
clocks).  Without the data pins going back to the chains for the scan the
test fails (6044 of 74570: only the ICU's held scan after the release put
them out).  Verilator and icarus.  lisa_sim has no TTLC and no model of
these registers.

**Cost.** About ten flops (the index, PEND, DONE and its edge), the
byte read mux and a write term per output and storage flop.  Hardened
2026-10-23 (runs/macro-ttlcio, rc16's recipe: a free draw with the art):
206179 um2 of standard cells against rc16's 203976 (+2203, +1.1%),
utilization 71.1% (rc16 70.5%), 61840 instances, 919K um of wire (+2%),
routing / Magic DRC, LVS and antenna 0, hold +0.074, setup +5.74 nominal
(rc16 +5.59) and -8.0 at the slow max corner (rc16 -6.8) - a path wholly
inside the core (ix -> the data address -> inst -> sp, no net of the TTLC
I/O, the peripherals or the SPI master on it), the address chain of rc13
(-8.2) and rc14 (-7.1), which moves from draw to draw.  Promoted as rc17 (2026-10-23).

## 31. The TTLC's storage: 64 bits

**Why.** Not a silicon issue: an extension (Ken, 2026-10-24), with the
room the 5x4 tile gave (rc18).  The TTLC's 32 storage bits (its internal
relays) are doubled.

**RTL** (`src/ttlc_io.v`).  `temp_storage` is 64 bits.  Bits 0-31 stay at
I/O addresses 96-127, so existing TTLC programs are unchanged; bits 32-63
are at 160-191, a block of 32 above the constants (138), so one compare of
address[7:5] decodes each range.  The read vector is 192 bits (139-159 read
0), padded to 256 so every 8-bit address reads a defined bit (above 191:
0).  The write decode was address[6] & address[5], which also took
224-255 as aliases of 96-127; it is now address[7:5] == 011 or 101 - a
program writing 224-255 now writes nothing (none of ours did).  The core's
byte view (item 30) grows to 24 bytes: 18-19 read 0, 20-23 are bits 32-63
and writable like 12-15; TIDX wraps after 23 (`lisa_ttlcio.v`).

**Test.** `test/progs/ttlc/ttlc_storage.asm`: the loopback through the
storage - inputs 0-31 to storage 32-63 (160-191), inputs 32-47 to storage
0-15 (96-111), and the storage to the outputs - with test_ttlc / test_ttlc_
debug / test_ttlc_jump's checks (`make TTLC=1
TTLC_IMAGE=progs/ttlc_storage_test.hex`): the outputs follow the inputs
only if the ICU writes and reads both ranges.  test_ttlc_debug steps round
the loop: its bound went from 120 to 300 steps (this loop is 194).
`test/progs/ttlcio.c`: check 1 the index wrap (17 to 18, 23 to 0), 0x0d
bytes 18-19 read 0 and ignore writes while 20-23 are written and read
back, 0x0e the low storage untouched by them.  Verilator and icarus.

**Cost.** 32 flops, the second write decode and the wider read muxes (the
ICU's bit mux 139 -> 192 inputs, the core's byte mux 18 -> 24).  Hardened
2026-10-24 on rc18's recipe (runs/macro-storage64, a free draw on the 5x4
tile with the pixel Calvin): 218416 um2 of standard cells against rc18's
216010 (+2406, +1.1%), utilization 59.4% (rc18 58.9%), 82325 instances,
1123K um of wire, routing / Magic DRC, LVS and antenna 0, hold +0.065,
setup +5.69 nominal and -8.8 at the slow max corner (rc18 -7.5) - a path
wholly inside the core (ix -> inst -> the data address), the address
chain that moves from draw to draw; no net of the TTLC on it.  Not
promoted.

## 32. Timer 3: PWM and input capture

**Why.** Not a silicon issue: an extension (Ken, 2026-10-24) with the room
of the 5x4 tile - a timer with two PWM outputs and two input captures,
usable as a plain timer with its outputs off; the PWM is only for designs
that do not use the TTLC's I/O (it shares mux 3's pins otherwise).

**Registers** (`src/lisa_timer3.v`; `lisa_periph.v` 0x30-0x3F): PRE (a
tick every PRE + 1 clocks), TOP (the counter runs 0..TOP, reset 0xFFFF),
CNT (reading the low byte latches the high one; a low-byte write loads the
count with the high byte written before), CMP0 / CMP1 (PWMn high while CNT
< CMPn: duty CMP / (TOP + 1)), CAP0 / CAP1 (read only), CTRL ([0] EN,
[2:1] the PWM outputs, [5:4] / [7:6] the capture edges: off, rising,
falling, both), IE and STATUS (OVF, CMP0, CMP1, CAP0, CAP1; a 1 written
clears).  The capture inputs are synchronised by two flops; the PWM
outputs are flops.

**Interrupt.** INT_STATUS / INT_ENABLE are full (8 sources), so Timer 3 is
a ninth source: the core's request input is 9 bits (`lisa_core.v`), bit 8
vectors to 9 - the slot its casez already gave the default and that
sdcc's vector table (`__interrupt(9)`) and NuttX's lisa_head.asm
(_lisa_irq8) already have.  Its enable is Timer 3's own IE (the core's
enable bit 8 is tied to 1).

**Pins** (`lisa_io_mux.v`).  Mux 2 had UART2's transmit on four pins (uo[0],
[1], [2], [7]); PWM0 takes uo[1] and PWM1 uo[2] while CTRL enables them,
else they stay UART2's: the SPI pins (uo[3], [5], [6]), the debug UART
(uo[4]) and UART2's uo[0] / uo[7] are untouched.  The captures watch
ui_in[4] / ui_in[5] (Port A 4-5, the TTLC's chain inputs in mux 3).

**Test.** `test/progs/timer3.c` (`make TIMER3=1`; `tb.v` cap_period drives a
square wave on ui_in[5:4], pwm_high0 / pwm_high1 count the PWM pins' high
clocks): the reset values and readback, a 16-bit count written and read,
the plain timer's OVF and its clear, the compare flag, the captures (a
rising edge 6000 clocks after the last and a falling one 3000 after it,
exact), the interrupt on vector 9 and none with IE clear; after the run the
testbench measures PWM0 at 25.0% and PWM1 at 75.0% of a 100-clock period
(5000 / 15000 of 20000 clocks).  Verilator and icarus; the chip bench's
interrupt programs (test_irq, test_irq2, test_uartirq, test_ldirq) still
pass with the 9-bit request.  lisa_sim (`timer3.h`): the registers, the
counter, the flags, the captures from port A bits 4-5 (`--cap-wave N`: a
square wave there) and source 8 on vector 9; sdcc_test/test_timer3.c is
the same program (make check REV3=1).  sdcc's lisa/tt07.h names the
registers and LISA_INT_TIMER3.

**Cost.** About 150 flops (the counter, prescaler, TOP, two compares, two
captures, the CNT latch and buffer, CTRL, IE, STATUS, the synchronisers,
the PWM flops) and the 16-bit comparisons (two less-than for the PWM, three
equalities for the flags).  Hardened 2026-10-24 with item 31 (runs/
macro-timer3, rc18's recipe on the 5x4 tile): 226036 um2 of standard cells
against item 31's 218416 (+7620, +3.5%; my estimate of 2-3K was low: the
comparators and the 16-bit registers' write muxes cost more than the
flops), utilization 61.2%, 81216 instances, 1179K um of wire, routing /
Magic DRC, LVS and antenna 0, hold +0.076, setup +5.44 nominal and -6.4 at
the slow max corner (the core's ix -> inst chain; no net of Timer 3 on
it).  Not promoted.

## 33. A WS2812B LED string driver

**Why.** Not a silicon issue: an extension (Ken, 2026-10-24), like item 32
for designs that do not use the TTLC's I/O: it borrows the TTLC's flops
for its buffer and the TTLC's mux-3 pins for its outputs.

**Design** (`src/lisa_ws2812.v`; Ken's idea: the TTLC's flops as the
holding registers, only the timed engine new).  The pixels are the TTLC's
48 output flops (`ttlc_io.v` output_pins), which the core writes through
item 30's window: half A bytes 0-2, half B bytes 3-5, each G, R, B.  The
engine walks the half being sent bit by bit (MSB first) through a 48:1
mux - no 24-bit holding or shift register - the bit's high time T0H or
T1H clocks of a TBIT + 1 period, then frees the half (FULL clear) and goes
on with the other if it is full.  With nothing full the line stays low;
after (TRST + 1) x 64 clocks DONE is set and the next frame starts at half
A; a pixel arriving after a gap but before the reset sets UNDERRUN (a
FULL written in the clock the last pixel ended does not).  Registers
0x40 WS_CTRL (EN, PIN, IE), 0x41 WS_STAT (FULL_A, FULL_B, BUSY, DONE,
UNDERRUN, NEXT; a write sets FULL, clears UNDERRUN), 0x42-0x45 WS_T0H /
T1H / TBIT / TRST (reset 20 / 40 / 62 / 219: 0.4 / 0.8 / 1.26 us, 282 us at
50 MHz).  The MC14500B must be halted (it writes the same flops).

**Pins** (`lisa_io_mux.v`).  In WS mode mux 3's uo[0], uo[1], uo[2] (the
chains' data), uo[5] (latch) and uo[6] (shift clock) carry the line on the
selected one and low on the other four; the SPI master's claim still
comes first on uo[0..2].  EN off gives the pins back to the TTLC - its
data shows on them, and the latch idles high - so EN stays on while
strings are attached (the first test switched pins with EN toggled off
and put a spurious bit on the string: the pin is now switched with EN on).

**Interrupt.** No new source: with IE set the free-half request (EN, IE
and a half not full: a level) takes the TTLC's source 5 (vector 6) in
place of the TTLC's toggle (`lisa_periph.v` int_req).

**Test.** `test/progs/ws2812.c` (`make WS2812=1`; uo[0-2], [5], [6] in mux
3; `tb.v` ws2812_rx decodes uo[1] and uo[2] - 12-28 clock highs are 0s,
32-48 1s, 10000 clocks low ends a frame - and counts edges on the three
idle pins once a pixel has been decoded): the reset values, frame 1 of 8
pixels on uo[1] through the ping-pong halves, frame 2 of 3 on uo[2], the
vector-6 request and its handler dropping IE, frame 3 of 2 with the second
late (UNDERRUN, cleared by a 1); the testbench checks every pixel and its
order (a hash: uo[1] 10 pixels in 2 frames, uo[2] 3 in 1), no malformed
pulse and no edge on the idle pins.  The first version of the design
continued a frame's half parity into the next: frame 3 waited on half B
- every frame starts at A now.  Verilator and icarus; the TTLC, SPIM and
TTLCIO suites still pass.  lisa_sim (`ws2812.h`): the registers, the
pixel timing, BUSY / DONE / UNDERRUN / NEXT and the request on source 5
(not the pixels or pins: it has no TTLC); sdcc_test/test_ws2812.c (make
check REV3=1).  sdcc's lisa/tt07.h names the registers.

**Cost.** About 60 flops (CTRL, the four timing registers, FULL, NEXT,
BUSY, DONE, UNDERRUN, the 5-bit bit counter, the 8-bit bit timer, the
14-bit reset counter, the line) and the 48:1 bit mux.  Hardened
2026-10-24 with items 31 and 32 (runs/macro-ws2812, rc18's recipe on the
5x4 tile): 231040 um2 of standard cells against item 32's 226036 (+5004,
+2.2%), utilization 62.4%, 80536 instances, 1198K um of wire, routing /
Magic DRC and LVS 0, hold +0.075, setup +5.37 nominal and -8.8 at the slow
max corner (the core's ix -> inst chain; no net of the driver or Timer 3
on it), and one antenna violation left after repair_antennas: a clock
leaf (clknet_leaf_24_clk_regs) at one flop's CLK pin, met1 partial ratio
434 against 400 (1.09x) - a property of this draw (rc18, items 31 and 32
alone had none); a release candidate is re-hardened.  Not promoted.

## 34. QSPI at clk/2: a write burst's word boundaries, and a late read capture

**Why.** The Arty's WS2812 run (item 33) underran on fetch speed: the
QSPI at clk/4 (0x1E = 0x0811) has been the board's limit, and clk/2
(0x0010) failed with the data cache on (Ken: "I'm still surprised the
QSPI won't run with clk/2, especially at 50MHz").  Flash-only programs
run at clk/2.  The suspicion was the read sample: `lisa_qqspi.v` shifts a
read bit in on SCLK's rising edge, one clock (20 ns at 50 MHz) after the
falling edge on which the part changes it, and the round trip through the
pads, the board and the part's clock-to-output is close to that.

**What it was: the writes.**  The PSRAM written and read from the
debugger with the core halted (1 KB through the cache, a pattern written
at one 0x1E and read back at another): reads at clk/2 of what was
written at clk/4 are right; what is written at clk/2 has the high nibble
of even bytes wrong - the first nibble of every word after the first in a
burst - as a bit-by-bit mix of that nibble and the last one of the word
before (0x36 read 0x76: 3 = 0011 and 5 = 0101).  After a word S7 drops
SCLK; S6 loads the next word into spi_buf but left sio_out alone, so the
first nibble reached the pins in the transfer's first clock - which at
clk/2 is the rising edge itself: the data changed on the edge the part
samples it.  At clk/4 the divider's clock in between hid it; the first
word after the address is safe (SCLK is still high there, a falling edge
comes first).  The testbench could not see it: the models sample in the
same time step, before the data changes.  **Fix**: S6 drives the word's
first bit (nibble) on a write.

**And a late read capture** (0x1E [14:13], one bit per select:
`rd_late`): a read bit is still shifted in on the rising edge and taken
again from the pins on the falling edge that follows, nearly a whole SCLK
period after the part changed it; what goes out still changes on the
rising edge (spi_mode, [12:11], moves both, and at clk/2 the outgoing bits
then change on the edge the part samples them: 0x1810 / 0x1010 hung on
the Arty).  `late_pend` says the bottom bits are the ones the last rising
edge shifted in: a phase that ends on a rising edge has the next one's
command or address loaded while SCLK is still high, and that falling edge
must not overwrite it (the first version did, and nothing ran even with
no delay).  The last bit's falling edge is the clock S7 runs: S7 takes it
there and builds rdata from it.  Ignored on a select with spi_mode set.
`debug_regs.v`: the register's latches to 15 bits, read back.  The Arty
does not need it (its reads at clk/2 are right); the chip's pads and a
slower part may.

**Test.** `tb.v`: SPI_DOUT_DLY=<ns> (`make SPI_DOUT_DLY=3`) has the
flash and PSRAM see the chip's data lines that much after SCLK - with 3 ns
test_core (CACHE=1) fails at clk/2 and passes at clk/4 before the fix, and
passes at clk/2 after it; SPI_TCO=<ns> delays what the parts drive on the
way back - at SPI_TCO=24 the default suite and test_core fail at clk/2
without the late capture and pass with it (SPI_REG=0x6010; lisa.py's setup
writes 0x1E from SPI_REG, default 0x0010), as do 0 and 36 ns.  With
SPI_DOUT_DLY=8 SPI_TCO=24 SPI_REG=0x6010 the default suite, test_core and
test_divc (CACHE=1), the TTLC, SPIM, TTLCIO, TIMER3, WS2812 and OVERRUN
suites pass, and everything as before without them; Verilator and icarus.
(`make BANK=1` fails at HEAD as well: progs/bank.c is the rev-2 bank test,
which rev 3's bank registers no longer match.)  sdcc_test/hw_psram.c: the
pattern test as a program (on the Arty at clk/2 before the fix its own
stack in the PSRAM went first).

**On the Arty** (2026-10-24, 50 MHz, setup +0.189 / hold +0.040 ns,
build/lisa_arty_r3_50_respin34.bit on andromeda): the debugger's pattern
test clean in every combination of clk/4, clk/2 and clk/2 with the late
capture; test_core, test_divc and hw_psram pass at 0x0010 and 0x6010 as
at 0x0811 (hw_psram 1.71 s against 3.22 s at clk/4); item 33's
test_ws2812 (the asm ws_put, TBIT 74), which underran at clk/4, passes at
clk/2 (five runs of five).  arty_run.py's default SPI is 0x0010 now.

## 35. The WS2812B driver's DMA

**Why.** Item 33's driver needs a pixel every 30 us from the core, and on
the Arty a loop that reads its pixels from the PSRAM does not keep up at
the datasheet's bit even at clk/2 (item 34; sdcc_test/hw_ws2812_miss.c:
a line fill every 5 pixels costs ~330 clocks a pixel over the 1800 budget
at TBIT 74, the worst case ~3300): a fill takes the QSPI bus from the
fetch, which starts its stream over.  Ken (2026-10-24): in WS mode the
TTLC is halted anyway - put a base address and a length in the output
flops instead of pixels and let the driver fetch the frame through the
TTLC's instruction fetch, whose group of three words is two pixels.

**Design.**  WS_CTRL [5] DMA, [6] REPEAT; WS_STAT bit 6 written is START,
read ACTIVE; bit 7 FRAME (sticky, a 1 clears it).  The output bytes 0-1
are BASE (the buffer's data address / 256), 2-3 LEN (pixels [12:0]).
START: the data cache's flush (the debugger's: the dirty lines written
back, `data_cache_flush` ORed at the top; a disabled cache counts as
flushed), the fetch idle, then `restart` - ttlc_fetch.v's group 0, both
groups dropped - and SEND: the engine's 48:1 bit mux takes group A
(`buf_a`) for the halves, the pixel of the group `pg` for NEXT; after a
group's second pixel (or the last) `adv` moves the fetch on (A from B,
which was prefetched; no prefetch past the last group).  In DMA mode
ttlc_addr = {data base, 0} | (BASE x 256 + the group's byte offset: an
add, a frame passes 256 bytes) on the data cache's select; the
MC14500B's run is held off.  A frame ends after the last pixel's reset
time: FRAME set, then IDLE or (REPEAT) the next frame, flushed again.  The
request in DMA mode is EN, IE and FRAME.  UNDERRUN: more than 8 clocks
low between pixels (A comes from B in two).  A group lasts 3000 clocks at
TBIT 62 and takes ~70 at clk/2; the arbiter is round-robin and the core's
stream yields, so a group waits for one transfer at most.

**Found on the way: the cache served the core during a flush.**  The
flush walks the lines with cache_map = the flush's line; a core access
whose tag matched that line's was a hit and read or wrote that line's
bytes (the debugger's flush always had the core halted).  In the REPEAT
test the program's loop counter on the stack came back wrong (3 frames
counted with no FRAME seen).  `data_cache8.v`: no hit while
flush_active - the core waits.

**Test.** `test/progs/wsdma.c` (`make WSDMA=1`, the cache on): frame A,
7 pixels on uo[1] written just before START (dirty in the cache: the
flush) - an odd length; an empty frame (LEN 0); frame B, 100 pixels (300
bytes, past 256) on uo[2] while the core thrashes one cache line (a
write-back and a fill on every access), the request at its end; frame C,
3 pixels with REPEAT, two FRAMEs seen and cleared before REPEAT is
cleared.  tb.v's receivers check every pixel and its order (uo[1] 16
pixels in 4 frames - C ran 3 times - uo[2] 100 in 1), no malformed pulse,
no edge on the idle pins.  Verilator and icarus; the other suites pass
(with SPI_DOUT_DLY=8 SPI_TCO=24 SPI_REG=0x6010 and without), test/core
too.  lisa_sim (`ws2812.h`): the DMA's timing, ACTIVE, FRAME, REPEAT and
the request (no pixels: no TTLC; the TTLC I/O window's writable bytes are
kept for BASE / LEN); sdcc_test/test_wsdma.c (make check REV3=1).  sdcc's
lisa/tt07.h: WS_DMA, WS_REPEAT, WS_ACTIVE, WS_START, WS_FRAME.
sdcc_test/hw_wsdma.c for the Arty: 200-pixel frames at TBIT 62 with the
core idle and thrashing, then REPEAT.

**On the Arty** (2026-10-24, 50 MHz, setup +0.013 / hold +0.019 ns,
build/lisa_arty_r3_50_respin35.bit on andromeda; no LEDs attached, the
driver's own flags and timing): hw_wsdma, a 200-pixel frame in 4981
64-clock ticks at clk/2 against 4945 for the pixels and the reset (the
flush and the first group ~2300 clocks), 4975 with the core thrashing
the cache throughout (328 write-back + fill iterations meanwhile), REPEAT
4967 a frame; no UNDERRUN in any; at clk/4 (0x0811) 5004 / 4999 / 5041,
no UNDERRUN either.  test_wsdma passes at clk/2 and clk/4 (its thrash
count check lowered to "the core ran": ~90 iterations in frame B at
clk/4).  The first run after programming the FPGA printed nothing; every
run since passed.
2026-10-25: real LEDs - an Adafruit NeoPixel Jewel (7 WS2812B) on uo_out[0]
(the Arty's JB1) runs Ken's TinyQV LED demo ported to LISA
(sdcc_test/hw_leddemo.c: zip, star crossed, wipe, circle, rainbow, fade;
7 pixels G R B in a PSRAM buffer, START, FRAME, Timer 3 delays) at clk/2;
Ken: "It works!!!".

**Cost.**  About 25 flops (the state, the 13-bit pixel count, the pixel
of the group, FRAME, the flush request, the two strobes), the 48-bit 2:1
mux into the bit mux, the 24-bit address adder and mux, the select mux.

## 36. A cycle counter, a watchdog and a PDM mode for Timer 3

**Why.** Not a silicon issue: extensions (Ken, 2026-10-25) after a review
of what a small microcontroller still lacked - no analog on this tile, so
no ADC or DAC; USB and Ethernet would need DMA and are better as external
modules.  These three are digital, small and broadly useful.

**Cycle counter** (`src/lisa_cyccnt.v`, 0x48-0x4B): 32 bits of clocks,
wrapping every 86 s at 50 MHz.  Reading CYC0 latches CYC1-CYC3, so the four
reads are one value; a write to CYC0 clears it.  For timing and profiling
(the 16-bit Timer 3 wrapped in several measurements).

**Watchdog** (`src/lisa_wdt.v`, 0x4C-0x4F): enabled, it must be kicked
(0xA5 to WDT_KICK) within (TIMEOUT + 1) x 2^(16 + SCALE) clocks - 1.3 ms to
43 s at 50 MHz - or it resets the core (the debugger's core reset, ORed:
the program restarts at 0) and the peripherals (`lisa_periph.v`'s rst_n
ANDed with it at the top), for 7 clocks.  Not itself (its own power-on
reset port, rst_por_n), the debug registers or the QSPI configuration -
a full chip reset would lose the host's QSPI setup and the chip could not
fetch.  After it fires EN is clear and WDRST (WDT_STAT bit 0, sticky, a 1
clears it) set, so a program can tell the restart from a power-on.

**PDM** (`src/lisa_timer3.v`, IE [6:5]): each of Timer 3's channels can be
a first-order sigma-delta modulator instead of an input capture - each
clock CAPn's low 9 bits take {0, CAPn[7:0]} + CMPn[7:0] and the carry is
the output, a density of CMPn[7:0] / 256, on the channel's PWM pin (CTRL's
PWMn out, uo[1] / uo[2] in mux 2); that channel captures nothing.  PWM is
unchanged on a channel left in capture mode.  Through an RC low-pass (1
kOhm and 10 nF for audio) it is an 8-bit DAC.  The first version was its
own module (lisa_pdm.v, 0x50-0x52, 36 flops); Ken: the PDM takes the PWM
pins anyway - a subset of Timer 3 reusing the compare and capture flops
(the rc22 draw with it routed far worse than rc21: 79 violations at the
25th detailed-route iteration against 6), and per channel, so the
captures stay available.

**Test.** `test/progs/misc36.c` (`make MISC36=1`, Verilator and icarus): the
cycle counter over a loop and cleared; the watchdog (TIMEOUT 1, SCALE 0:
131072 clocks) kicked every 60000 clocks five times without firing, then
left: it resets, the program restarts and finds WDRST set and EN clear;
Timer 3's channels in PDM mode at 64 and 192, measured by test.py on uo[1]
/ uo[2] over 25600 clocks: 25.00% and 75.00%; the Timer 3 test (PWM at 25%
/ 75% and both captures) unchanged.  The other suites (TIMER3 and WS2812 share
the pins and the peripherals' reset) pass.  lisa_sim (`misc36.h`): the
counter and the watchdog (resetting the core and the peripherals but not
itself), Timer 3's IE bits;
sdcc_test/test_misc36.c (make check REV3=1: 39/39).  sdcc's lisa/tt07.h:
CYC0-3, WDT_*, T3_IE_PDM0 / 1.
On the Arty (2026-10-25, 50 MHz, setup +0.128 / hold +0.018 ns,
build/lisa_arty_r3_50_respin36.bit on andromeda): test_misc36 three runs
of three, the watchdog reset and the restart from the flash each time.

**Cost.** The counter 56 flops (32 + the 24-bit latch), the watchdog 47
(23-bit prescaler, 8-bit ticks and timeout, scale, EN, WDRST, the reset
pulse), the PDM 2 (the mode bits: the accumulators are CAPn, the levels
CMPn).

## 37. DDR instruction reads (an option)

**Why.** lisa_sim's fetch model (`--icache=0x8,window`, the chip's
streaming window, with `LISA_ICACHE_WORD=` for the word time) on the SDCC
suite: at 10 clocks a word the fetch is still most of the time of
straight-line code (6.55 clocks an instruction against 3.79 with a free
fetch).  The flash on the Tiny Tapeout QSPI Pmod is the W25Q128JV-DTR
(JEDEC ID EF 70 18; its datasheet: DTR reads at up to 66 MHz, tCLQV 6 ns,
tCLQX 1.5 ns), which reads on both SCLK edges: 2 SCLK a word instead of 4.
Modeled: DDR 1.28x (to 1.56x a program), DDR without the 2-clock pause
per word 1.49x (to 2.16x), the pause removed in SDR 1.12x; the flash's
continuous-read mode would add little (the window already avoids most
restarts).  Ken: as an option - off at reset, so nothing depends on it if
it does not work on silicon.

**The read.** A read of a quad flash select with its 0x17 DDR bit (bit 6
CS0, bit 7 CS1) that is an instruction burst or a single word (the
debugger's 0x20) is EDh: the instruction on IO0 as before, the falling
edge after it unused (a DTR part takes no address there), the address and
the mode byte (0xFF, never continuous-read) a nibble on each edge, then
`ddr_dummy` (0x17 [15:12], reset 7) dummy clocks and the data a nibble on
each edge.  SCLK goes out half a clock late for the whole read (`sclk_n`,
a falling-edge flop, selected by `dtr`), so the nibbles the chip drives on
a clock edge are half a clock either side of the SCLK edge that takes
them.  Every other access (multi-word reads, writes, the debugger's
commands, a RAM select) is as before.

**The capture.** The data does not come in through the shift register but
through a pipeline (state S13_RUN): every SCLK edge that launches a nibble
(each edge in DDR, the falling ones in SDR) is marked in `cap_pipe`, and
the nibble is taken `ddr_cap + 1` half clocks after the clock that made
the edge - an odd `ddr_cap` from the pins at a rising edge of clk, an even
one from `sio_neg`, the pins at the falling edge before.  Half-clock steps
from 0.5 to 4 clocks: the window of a DDR nibble is one clock at clk/2, so
whole-clock steps could miss it for some round trips.  The host finds the
point: the debugger reads words of the flash in SDR, then in DDR at each
point, and takes the middle of the ones that agree (`arty_run.py
DDR=auto`).  Four nibbles make a word in `spi_buf[15:0]`; in a burst the
word goes to rdata / ready as its last nibble comes in, while the next
word's edges already run: edges are issued while fewer than 4 nibbles are
in flight, or fewer than 8 with ready free, so a word is held until the
client takes it (ready drops for a clock after each ready_ack, as
inst_stream.v's `pushed` expects).  A single word goes to S7 as before.
`seamless` (0x17 [8]) runs the SDR bursts (EBh) through the same pipeline,
without the S7 / S6 pause: 8 clocks a word.

**Changing it.** `dtr` and `run` are taken at the command (S2): a burst
open when 0x17 changes goes on as it began, the next one takes the new
setting, so the bits can be changed while the core runs from the flash.
`ddr_cap` acts at once (a sweep runs with the core halted).

**Test.** `make DDRSWEEP=1` (test_ddr_sweep): the sweep as above with
the 32 first words, then hello in DDR at the middle point, and SDR again
after a reset.  The flash model (`test/spiflash.v`) does EDh as the
datasheet's Figure 27a, the first data nibble on the falling edge of the
last dummy clock or (+DTR_LAUNCH=1) the rising edge after it.  Verilator:
points 1-2 pass, 3-4 with DTR_LAUNCH=1; icarus with SPI_TCO= round trips:
the passing points move with the round trip as expected - 5 ns: 1-2, 12
and 18 ns: 2-3, 25 ns: 3-4, 35 ns: 4-5 (SDR with 0x1E's late capture at
25 and 35), 12 ns with DTR_LAUNCH=1: 4-5 - and hello runs in DDR at each
(tb.v's SPI_TCO / SPI_DOUT_DLY are transport delays now: a continuous
assign's inertial delay swallowed the 20 ns DDR nibbles past 20 ns).  `DDR_CAP=<n>` / `SEAMLESS=1` set the bits for any test:
the REV3 SDCC suite (run_suite.sh chip REV3=1) passes 28 of 28 in DDR and
in seamless SDR; `DDR_TOGGLE=<clocks>` flips the DDR and seamless bits
while a program runs from the flash (test_core with the cache, every 613
to 3001 clocks: ALL PASSED).  test_core's fetch: 5.3 clocks an instruction
in SDR (23% waiting for the flash), 5.1 seamless, 4.7 in DDR (15%).  With
the bits clear: the default suite, TIMER3, WS2812, WSDMA, SPIM, TTLCIO,
OVERRUN, I2C, MISC36 and TTLC pass, the REV3 SDCC suite 28 of 28 on the
chip bench and 27 of 27 on the core bench (BANK fails as it did before -
a rev-2 program).  On the Arty (2026-10-25, 50 MHz, setup +0.028 / hold
+0.015 ns, build/lisa_arty_r3_50_respin37.bit on andromeda, the TT QSPI
Pmod's W25Q128JV-DTR, io mux mode 3, the cache on): `arty_run.py
DDR=auto` finds points 2 and 3 (the others misread nearly every word) and
runs at 3; the REV3 suite 27 of 27 in DDR, NuttX's nsh boots and runs
(free, ls); test_divl 0.38 s in SDR, 0.33 s seamless, 0.23 s in DDR
(1.65x).

**Cost.** 28 flops: in the engine `dtr`, `run`, `sclk_n`, `sio_neg` (4),
`cap_pipe` (4), the nibble count (2), `word_full`, `inflight` (4); in
debug_regs 0x17's ten bits.  The word is assembled in `spi_buf`.

## 38. The slow corner: the data address and lda (ix++)'s fetch

**Why.** rc23's slow max corner (Ken, 2026-10-25): 183 setup violators,
all but 16 starting at op_ldk_r.  The path (rc23, -8.7 ns at 30 ns):
op_ldk_r (5 ns of fanout tree) -> kfetch -> the fetch address mux and the
code bank mux -> inst_stream's window subtract and hit (12 ns) ->
inst_ready -> `inst = inst_ready ? inst_i : inst_r` -> the data address
adders (sp + offset, ix + offset; 13 ns) -> d_addr -> tt_um's d_addr_good
compare -> d_ok -> the enables of ia, pc, sp, ra, ix, acc and the rest.
The other 16: inst_r -> the BF16 cone -> facc, timed as one clock because
inst_r was in no lisa.sdc group (its comment of 2026-10-20 said the cone
started at 3-cycle sources).

**inst_r for what the instruction does.** `inst` differs from `inst_r` only in a
fetch that has its word and in lda (ix++)'s constant fetch, and in neither
is there a data access (d_valid 0; d_rd needs the exec state).  From the
predecode state on they are the same word, so d_addr_r - registered every
clock - holds the instruction's address from two clocks before its exec,
as before.  d_addr_imm, d_addr's offsets, sp_adder, sp_addr, ix_addr and
d_periph read inst_r now (rc24), then (rc25) the 40 other exec-time uses -
ix_sum, pc_rel, the immediates of adc / cpi / ldi / andi / reti, ldc,
ldz, btst, the if condition, the divider's arguments, amode, ei / di, the
ldx words, taf / tfa, d_valid_rd's swapi / lda: the decoders (op_*,
jump_taken ...) are what still reads `inst`, so the window lookup ends at
their flops.

**kfetch its own flop.** `kfetch_q` is set as an lda (ix++) with its
predicate goes from decode to exec and cleared when its exec ends (d_ok)
or on a reset - the value of exec_state & op_ldk_r & cond[0], without
op_ldk_r's fanout and the AND in front of the fetch address.  A
simulation check (lisa_core.v, not synthesized) stops the run if the two
ever differ.

**The TTLC flag in two status bits.** FLAG_O, the ICU's flag, is a
falling-edge flop; read through SPI register 0x2B bit 3 (scan_req & owned)
and TTLC I/O register 0x2E bit 3 (ttlc_wait) it was a half-clock path
into the core's read data (rc24: -2.2 ns into the divider).  Both bits
are read from a rising-edge copy now (`scan_req_r`, `ttlc_wait_r`): a
clock late, status only - the interlock itself still uses the request.

**lisa.sdc.** Sources that were in no group, so timed as one clock: inst_r
(loaded as a fetch ends, or by lda (ix++)'s constant fetch as its exec
ends) to core3 - the registers written at an instruction's end, in its
decode state at the earliest, two clocks later (none is written in the
predecode state) - `lisa_mcp 2 $inst_r $core3`; the BF16 operation flags
(registered from the decoded word as the fetch ends) to facc; facc and
f0-f3 to facc (written in an exec state: the next write is four clocks
on at the least).  The f registers' nets carry the debugger's names in the
netlist ($dbg.f0, as the breakpoint registers do), which rc26 missed.

**Test.** Every suite as before with the check on: the default suite,
TIMER3, WS2812, WSDMA, SPIM, TTLCIO, OVERRUN, I2C, MISC36, TTLC, DDRSWEEP,
icarus, the REV3 SDCC suite 28 of 28 on the chip bench (and 28 of 28 in
DDR) and 27 of 27 on the core bench (lda (ix++) is in most of them:
test_strs 43 times); no kfetch_q mismatch.  The core bench's debugger
tests: the breakpoint after a store and halt / resume pass, single step
fails as it does at HEAD (rc23).  On the Arty (rc24's RTL,
build/lisa_arty_r3_50_respin38.bit, setup +0.026 / hold +0.033 ns): the
REV3 suite 27 of 27 in SDR and in DDR, NuttX's nsh and the OLED splash.

**Hardened** (rc23's recipe; every run DRC / LVS / antenna clean, no cell
on Calvin's pixels; the slow max corner's worst setup slack and violating
endpoints): rc23 -8.74 (183), rc24 the address from inst_r and kfetch_q
-5.27 (38), rc25 the other exec-time uses and the status bits -4.93 (45),
rc26 inst_r -> core3 and facc -> facc -4.65 (29), rc27 the f registers'
names -1.41 (9); then (lisa.sdc only) rc28 the divider's second-stage
flags (lddiv / div / rem_stage_two: set as the first word's exec ends,
held through the second word's fetch, predecode and decode) to core3 two
clocks -0.49 (2), rc29 the decoded flags op_*_r (registered every clock
from inst, so they change when inst_r does) to core3 two clocks -0.44
(1); rc29 nominal +5.23, nom_ss +0.48 (0), min_ss +1.49 (0).  Left, at
the slow max corner only: stage -> sp_adder's `2 - stage` (ldxx / stxx
n(sp)) -> the stack-offset adder -> d_addr -> d_addr_good -> d_ok -> ra,
a real one-clock path - each stage of a pair instruction moves the data
address in the clock d_ok is decided.

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
  mask), and the ISA document (`ldamode` is in sdaslisa and lisa_sim since item 24).
* Item 26's toolchain side: a packed CONST area (`.db` as bytes, not pairs),
  `__gptrget` on `lda (ix++)`, KB set by the startup, NuttX's CONST in a bank.

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
* rc3 (2026-10-17, night; runs/macro-rc3 on 37500a3: items 17-20 and
  lisa.sdc's `win_data` on top of rc2, the same recipe - fanout 16, hold
  margin 0.07, rc2's placement as the anchor table): hardened clean on the
  first run.  Synthesis 20063 cells / 150.2K um2 (rc2 19401 / 144.6K,
  +3.9%: item 20's autobaud and generator twice over, the debug UART's and
  LISA's, two thirds of it, the TTLC slot format most of the rest - a
  hierarchical Yosys stat of both trees, since the flattened netlist does
  not say).  The anchor table matched 5354 cells (rc2 replayed 6644 of
  rc1's; 317 registers are new or renamed).  Placed at 65.8% (64.2%),
  routed in 54 iterations (rc2 13; the global route's overflow 181
  against 68, met2 at 79.6% against 76.9%), 913K um of wire (889K), Magic
  DRC / LVS / antenna 0, both power nets connected, hold +0.078 ns at the
  fast corner (0.077), setup +5.4 ns nominal and -4.7 / -5.7 at the ss
  corners (rc2 -5.8 / -7.2: the window-data exception), 525 hold buffers
  (576), max-slew 1859 (1868), max-fanout 35 (35), max-cap 6 (3).
  Promoted 2026-10-18 (Ken): gds/, lef/, pnl/ are rc3's, macro.json's
  anchor table its placement (placements/macro-rc3_final_cells.json);
  rc2's placement stays an option (`make macro OVERLAY=trial_anchor_rc2.json`,
  and `trial_anchor_free.json` is a free draw).  Tag rc3; the
  gds workflow's precheck is next.
* Chip art and a free draw (2026-10-18): Ken's calvin, the met4-only
  picture of ihp-um-janestreet-prism, on this tile.  `harden/chip_art.py`
  (prism's tool for sky130A: met4 71/20, the rules of sky130A_mr.drc met
  on a 0.6 um pixel grid - m4.1/m4.2 width and spacing 0.3, m4.4a area
  0.24, m4.7 holes 0.2, m4.5ab 0.4 to 3 um wide metal, and m4.11, no solid
  metal wider than 10 um both ways, which calvin's ink strokes meet by
  themselves - re-checked on the merged shapes) re-grids prism's hand-edited
  cell (`harden/art/calvin/source.gds`) onto the 54 x 79 pixel box that
  fits the channel between a PDN stripe pair and the next (32.4 x 47.4 um).
  As in prism the picture sits on bare oxide (Ken: that is what makes it
  visible): `Project.ArtKeepout` (flow.py, `odb_art_keepout.py`) cuts the
  rows under the box after OpenROAD.CutRows, `ROUTING_OBSTRUCTIONS` keeps
  the router off it on met1-met4, and `Project.ChipArt` merges the cell
  into every GDS view after Magic.WriteLEF (before Magic.DRC, which checks
  it in place) and adds the box to the tile LEF as a met4 obstruction;
  nothing of it is in the netlist, so LVS sees nothing.  The keep-out
  runs to the rows' end (x 679.88), not the art's edge: 3-site row stubs
  were a channel pdngen could not strap (PDN-0179).  Where: three
  free-draw trials to the global route - a met4-only box in the centre
  (x 296, y 460: 1.139M um of wire), the full keep-out at mid height on
  the right edge (1.151M, met3 45.4% / overflow 9) and in the upper-right
  corner (1.133M, met3 41.4% / 3).  Ken's structural argument decided it
  for the corner: nothing routes around a keep-out in a corner, the cells
  just move inward.  Found on the way: a free draw of the current netlist
  global-routes far lighter than the anchored replay rc3 was (rc3 1.322M
  um, met2 79.6% / overflow 82, met3 57.9% / 47; the free centre trial
  1.139M, 70.1% / 41, 41.2% / 2) - the replayed placement had carried
  rc1's distortion through rc2 into rc3 - so the harden with the art,
  rc4, is a free draw (`trial_anchor_free.json`), and its placement is
  the table to replay from then on.
* rc4 (2026-10-18, runs/macro-rc4-art on 635640b: rc3's RTL, the art, a
  free draw): routed clean in 21 iterations (34 with the two antenna
  reroutes), 790K um of wire against rc3's 913K, placed at 65.6%, Magic
  DRC / LVS / antenna 0, hold +0.076 ns at the fast corner, setup +5.6 ns
  nominal and -5.5 / -6.9 at the ss corners (rc3 -4.7 / -5.7: a different
  draw of the same unconstrained paths), 591 hold buffers (525), max-slew
  2174 (1859), max-fanout 38 (35), max-cap 2 (6).  The first pass had two
  Magic DRC errors, both in the art: met4.5a is a 0.4 um spacing within
  the band of metal 0.4 um around large (3 um) metal, and where thin
  metal leaves a convex corner of the body on both sides the two band
  pieces meet at the corner point only, zero spacing to Magic (KLayout's
  m4.5ab does not see it); chip_art.py now fills the pixel diagonal to
  such a corner (one pixel in calvin, Magic DRC of the cell 0) and the
  run was resumed from Project.ChipArt (`flow.py --from=`), 0 errors.
  `harden/art/calvin/rc4_corner.png` is the corner of the GDS: the
  picture in met4 on bare oxide, the routing stopping at the keep-out,
  the stripe pair to its left and the edge stripe to its right.  The
  Tiny Tapeout precheck run locally on it (tt-support-tools/precheck:
  Magic DRC, KLayout FEOL / BEOL / offgrid / zero-area / pin-label,
  the pin, boundary, power-pin, layer, cell-name and nwell checks)
  passes.  Ken saw five empty rows across the picture: the slots I had
  cut for m4.11 (every 15th pixel row).  The picture needs none - its
  strokes leave no white area 10 um wide both ways, the self-check
  agreed with no slots, and neither the precheck's KLayout deck nor the
  PDK's current one carries the rule - so the art is regenerated without
  them (910 um2 of met4, Magic DRC of the cell 0) and the run's tail
  redone from Magic.StreamOut - a resume starts from the run's last
  state, which already carried the art, so a resume from Project.ChipArt
  had stacked a second art cell on the first (merge_art prunes an old
  art cell now).  The precheck passes on the slot-free GDS as well.
  Promoted 2026-10-18 (Ken): gds/, lef/, pnl/ are rc4's, macro.json's
  anchor table its placement (placements/macro-rc4-art_final_cells.json);
  rc3's and rc2's tables stay as overlays (trial_anchor_rc3.json,
  trial_anchor_rc2.json).  Tag rc4.
* rc5 (2026-10-18, runs/macro-rc5 on 9628a73: item 21's RTL, rc4's
  placement replayed as the anchor table, the art): clean (Magic DRC /
  LVS / antenna 0, hold +0.077, setup +5.6 / -5.6) and the local precheck
  passes, but 917K um of wire in 46 routing iterations against rc4's 790K
  in 34 - the anchored replay routed heavier again, as rc3 had after rc2.
  rc5-free (runs/macro-rc5-free, the same RTL as a free draw): clean,
  796K um, setup +5.4 / -5.0, the precheck passes.  Neither promoted:
  item 22 came the same day.
* rc6 (2026-10-18, runs/macro-rc6 on the RTL of f1257d1 - item 22, the
  bank registers - a free draw with the art): 63270 instances,
  synthesized 152770 um2 against rc5-free's 150557 (+1.5%: the three
  registers, the bank in each cache line's tag, the 18-bit addresses),
  placed at 66.6%, 824K um of wire in 57 iterations, Magic DRC / LVS /
  antenna 0, hold +0.075, setup +5.6 nominal and -4.9 at ss.  Its worst
  paths: the debugger's step flop into the BF16 accumulator cone (3-cycle
  in the FPGA's constraints, not in lisa.sdc), the debug data register
  into PC, the cache-map register into the RAM32's half-cycle write - all
  quasi-static or multicycle; a timing-only run of the routed design at
  20 ns closes at the typical corner with +1.2 ns, so a 50 MHz part at
  room temperature and about 30 MHz at the slow corner, consistent with
  TT07's 66 MHz under the same 30 ns constraint (which stays: tightening
  it would only upsize those cones).  The local precheck passes.  The
  banks' test runs on this RTL on the Arty (fpga/README.md).
  Promoted 2026-10-18 (Ken): gds/, lef/, pnl/ are rc6's, macro.json's
  anchor table its placement (placements/macro-rc6_final_cells.json);
  rc4's table stays as the overlay trial_anchor_rc4.json.  Tag rc6.
* rc7 (2026-10-18, runs/macro-rc7 on ea6105e: items 14 (the overrun flag)
  and 23 (the read strobe) on rc6's RTL, a free draw with the art): 63346
  instances, synthesized 153213 um2 (+0.3% over rc6), placed at 66.8%,
  810K um of wire in 32 routing iterations, Magic DRC / LVS / antenna 0,
  hold +0.075, setup +5.6 nominal and -4.6 at ss (the same quasi-static
  cones as rc6).  The local precheck passes.
  Promoted 2026-10-18 (Ken): gds/, lef/, pnl/ are rc7's, macro.json's
  anchor table its placement (placements/macro-rc7_final_cells.json);
  rc6's table stays as the overlay trial_anchor_rc6.json.  Tag rc7.
* rc8 (2026-10-18, runs/macro-rc8 on 3d1d952: the 6-bit code bank of item
  22 on rc7's RTL, a free draw with the art): synthesized 153457 um2 (+0.16%
  over rc7: the two bank bits, the 20-bit window and burst addresses),
  63239 instances, placed at 66.9%, 797K um of wire, Magic DRC / LVS /
  antenna 0, hold +0.077, setup +5.6 nominal and -4.6 at ss.  The local
  precheck passes.
  Promoted 2026-10-18 (Ken): gds/, lef/, pnl/ are rc8's, macro.json's
  anchor table its placement (placements/macro-rc8_final_cells.json);
  rc7's table stays as the overlay trial_anchor_rc7.json.  Tag rc8.
* rc9 (2026-10-18, runs/macro-rc9 on cd4d09d: items 24 (ldirq) and 25 (the
  UART interrupt enables written, the requests as levels) on rc8's RTL, a
  free draw with the art): synthesized 154326 um2 (+0.57% over rc8), 63156
  instances, placed at 67.1%, 828K um of wire in 14 iterations, Magic DRC /
  LVS / antenna 0, hold +0.077, setup +5.6 nominal and -3.8 at ss.  Not
  promoted: item 26 came the same evening.
* rc10 (2026-10-18, runs/macro-rc10 on 4217121: item 26 (lda (ix++) and the
  constant bank KB) on rc9's RTL, a free draw with the art): synthesized
  154384 um2 (+0.04% over rc9, +0.60% over rc8), 62660 instances, placed at
  67.6%, 822K um of wire in 14 iterations, Magic DRC / LVS / antenna 0,
  hold +0.079, setup +5.6 nominal (an output-port path, as before) and
  -6.4 at ss (262 endpoints; rc9's 68 at -3.8 sat on the BF16 accumulator
  cone).  The slow corner's worst path is new and item 26's: IX through
  the fetch window's address compare into k_ok / d_ok and the registers'
  enables (ix[12] -> ra[5], 40.0 ns of arrival against 33.6 required);
  fine at nominal.  A registered k_ok (one more cycle on lda (ix++)) would
  take it out if the slow corner ever matters.  The local precheck passes.
  Promoted 2026-10-18 (Ken): gds/, lef/, pnl/ are rc10's, macro.json's
  anchor table its placement (placements/macro-rc10_final_cells.json);
  rc8's table stays as the overlay trial_anchor_rc8.json.  Tag rc10.
* rc11 (2026-10-19, runs/macro-rc11 on 1f36114: item 27 (the restoring
  divider with the remainder in IX and the chained step divc) on rc10's
  RTL, a free draw with the art): synthesized 154265 um2 (-0.08% over
  rc10: one 17-bit subtractor and two negators in place of four
  compare-and-subtract pairs, 20 more flops), 63044 instances, placed at
  67.3%, 821K um of wire in 11 iterations, Magic DRC / LVS / antenna 0,
  hold +0.079, setup +5.8 nominal (the output-port path, as before), -5.5
  at nominal ss and -6.4 at the slow max corner (rc10: -6.4 and -7.7).
  The slow corner's worst path is the IX-to-address-compare cone again,
  now from ix[1] through d_addr and the register enables into facc[2]
  (93 nets, 40.0 ns against 33.6); the divider is not on it.  The
  max-cap / max-slew counts at ss are 78 / 8072 (rc10: 63 / 7639), open
  as before.  The local precheck passes.  Promoted 2026-10-19 (Ken):
  gds/, lef/, pnl/ are rc11's, macro.json's anchor table its placement
  (placements/macro-rc11_final_cells.json); rc10's table stays as the
  overlay trial_anchor_rc10.json.  Tag rc11.
* rc12 (2026-10-19, runs/macro-rc12 on item 28's RTL - the three-region
  data map, the data bank 5 bits, the cache tagged with physical bit 13
  and its lines indexed by address bit 14 - on rc11's, a free draw with
  the art): synthesized 154363 um2 (+0.06% over rc11: the wider data
  bank, the tag bit, the page mux), 62654 instances, placed at 67.5%,
  825K um of wire, Magic DRC / LVS / antenna 0, hold +0.066, setup +5.5
  nominal, -4.8 at nominal ss and -5.9 at the slow max corner (rc11: -5.5
  and -6.4); max-cap / max-slew at ss 72 / 7659 (rc11: 78 / 8072).  The
  chip testbench's bank test, the cache suites and the Arty (bitstream
  slack -2.30 ns; the SDCC programs and the banked NuttX) pass on the
  RTL.  Promoted 2026-10-19 (Ken; the precheck left to the gds workflow):
  gds/, lef/, pnl/ are rc12's, macro.json's anchor table its placement
  (placements/macro-rc12_final_cells.json); rc11's table stays as the
  overlay trial_anchor_rc11.json.  Tag rc12.
* rc13 (2026-10-20, runs/macro-rc13 on the third chip's RTL at 22f57c8 -
  REV3.md: IX, SP, RA and IA 24 bits with the condition bit at bit 23,
  three-byte pairs, ldxf, 128 code banks, the flat 8 MB in place of the
  bank registers; a free draw with the art): 61899 instances (the bank
  logic gone), placed at 70.0%, 900K um of wire, Magic DRC / LVS /
  antenna 0, hold +0.075, setup +5.65 nominal, -8.2 at the slow max
  corner, where the worst path is IX -> the n(ix)/n(sp) mux -> the 23-bit
  address adder -> the cache's tag compare -> the execute done -> facc's
  write enable: the widened address chain.  Not promoted.
* rc14 (2026-10-20, runs/macro-rc14 on b7d3941 - the BF16 operations take
  their f-register index from inst_r, which removed a path from the timing
  graph that was never real: the Arty closes 50 MHz with it): 62002
  instances, 69.8%, 884K um, clean, hold +0.076, setup +5.64 nominal,
  -7.1 ss (the worst path op_ldk_r -> sp, the kfetch logic).  Not
  promoted.
* rc15 (2026-10-20, runs/macro-rc15 on 8cd0dad - lisa_div's
  ldx_stage_two_r reset, missing on every revision and exposed by rev 3's
  ldxf startup: the predicate update is gated by ~ldx_stage_two, so with
  the flop up at 1 no `if` works until the first ldx): 62210 instances,
  69.7%, 898K um of wire, Magic DRC / LVS / antenna 0, hold +0.072, setup
  +5.57 nominal, -6.5 at the slow max corner (the worst path exec_state ->
  sp).  The chip testbench's suite 28/28, the test action green, the Arty
  at 50 MHz with NuttX.  Promoted 2026-10-20 (Ken; the precheck left to
  the gds workflow): gds/, lef/, pnl/ are rc15's, macro.json's anchor
  table its placement (placements/macro-rc15_final_cells.json); rc12's
  table stays as the overlay trial_anchor_rc12.json.  Tag rc15.
* rc16 (2026-10-22, runs/macro-spi-free - RESPIN 29, the SPI master on its
  own pins with the TTLC-pin interlock; a free draw with the art): 61852
  instances, 70.5%, 900K um of wire, routing DRC / Magic DRC / LVS /
  antenna 0, hold +0.077, setup +5.59 nominal, -6.8 at the slow max corner
  (the worst path op_ldk_r -> pc[9] in the core, not the SPI).  Promoted
  2026-10-22 (Ken; the precheck left to the gds workflow): gds/, lef/,
  pnl/ are this run's; macro.json's anchor table stays rc15's.
  The same day the top module became tt_um_pettit_lisa (the name
  tt_um_lisa was taken on the ttsky26d shuttle): src/tt_um_pettit_lisa.v,
  info.yaml, every reference; runs/macro-pettit re-hardened it with the
  same recipe and came out identical (61852 instances, 70.5%, -6.8 ss,
  clean), and gds/, lef/, pnl/ are its tt_um_pettit_lisa.* files.
* rc17 (2026-10-23, runs/macro-ttlcio - RESPIN 30, the TTLC's I/O from
  the core: the I/O vector as bytes at 0x2C-0x2E, scans the core starts,
  atomic updates under the SPI master's claim; rc16's recipe, a free draw
  with the art): 61840 instances, 71.1% (rc16 70.5%; +2203 um2 of
  standard cells), 919K um of wire, routing DRC / Magic DRC / LVS /
  antenna 0, hold +0.074, setup +5.74 nominal, -8.0 at the slow max
  corner (the worst path ix -> the data address -> inst -> sp, inside the
  core).  The chip testbench (Verilator and icarus: default, SPIM, TTLC,
  TTLC jump, OVERRUN, TTLCIO) and the core bench pass.  Promoted
  2026-10-23 (Ken; the precheck left to the gds workflow): gds/, lef/,
  pnl/ are this run's; macro.json's anchor table stays rc15's.  Tag rc17.
* rc18 (2026-10-24, runs/macro-rc18 - the 5x4 tile and Calvin as placement
  blockages; the RTL is rc17's): Ken moved to a 5x4 tile (856.52 x 511.36
  um, info.yaml) for room to grow, with the RAM32 two stripe pitches right
  (x 427.57) and his two-colour Calvin (art/calvin_nocircle/source.png,
  73 x 74) as 1016 placement-blockage pixels of two rows by 12 sites, 403 x
  403 um at (12.42, 97.92): no cell of any kind on a pixel (flow.py
  Project.ArtPixels; Project.ArtPixelTaps re-taps the rows it crosses - 447
  taps removed, 4761 added, every free segment within 7 um of a tap, for
  Magic's nwell.4 / LU.2 / LU.3; png2pixels.py fills a pixel where two
  touched only at a corner, Magic nwell.1).  The met4 Calvin is dropped.
  A free draw (the 4x4 anchor tables do not apply): 82404 instances, 58.9%,
  216010 um2 of standard cells, 1119K um of wire, global-route overflow 185
  (rc17 93), routing DRC / Magic DRC / LVS / antenna 0, hold +0.078, setup
  +5.60 nominal and -7.5 at the slow max corner (rc17 -8.0).  The trials
  that led here: on 4x4 two-row pixels of the met4 Calvin did not place
  (GPL-0301, 100.5%) and one-row pixels did not converge; on 5x4 the met4
  Calvin's lines (runs/macro-artpix-5x4), Ken's circled Calvin and Calvin
  without the circle routed clean.
* rc19 (2026-10-24, runs/macro-rc19 - RESPIN 31-33: the TTLC's storage
  to 64 bits, Timer 3, the WS2812B driver; Ken's updated Calvin, 997
  pixels; the RAM32 moved to x 505.31, as far right as the 5x4 tile allows,
  after the draw at 427.57 did not route well - runs/macro-rc19-ram427,
  stopped - and runs/macro-ws2812 left an antenna violation): 80612
  instances, 62.3%, 230804 um2 of standard cells, 1200K um of wire,
  global-route overflow 412 (macro-ws2812 1074), routing DRC / Magic DRC /
  LVS / antenna 0, hold +0.073, setup +4.96 nominal and -8.3 at the slow
  max corner (exec_state -> inst -> the data address, in the core).  The
  re-tap step removed 435 taps and added 4765; no cell on a pixel
  (art/calvin_nocircle/placement_rc19.png).  Promoted 2026-10-24 (Ken; the
  precheck left to the gds workflow): gds/, lef/, pnl/ are this run's.
* runs/macro-rc20 (2026-10-24 - RESPIN 34, the QSPI at clk/2): 62.5%,
  231556 um2 of standard cells, 1226K um of wire, routing DRC / Magic DRC
  / LVS 0, hold +0.047, setup +5.31 nominal and -8.5 at the slow max
  corner, and one antenna violation (a met3 side-area ratio 429 against
  400, one net, two pins).  Not promoted: re-hardened with item 35.
* rc21 (2026-10-24, runs/macro-rc21 - RESPIN 34 and 35: the QSPI at
  clk/2, the late read capture, the WS2812B driver's DMA and the data
  cache's flush fix; rc19's recipe): 80365 instances, 62.9%, 233220 um2 of
  standard cells (+2416 on rc19), 1221K um of wire, global-route overflow
  461, routing DRC / Magic DRC / LVS / antenna 0, hold +0.056, setup +5.51
  nominal and -7.7 at the slow max corner (from the core's exec_state, as
  rc19's).  The re-tap step removed 435 taps and added 4765; no cell on
  Calvin's 997 pixels (367 blockages).  Promoted 2026-10-24 (Ken; the
  precheck left to the gds workflow): gds/, lef/, pnl/ are this run's.
* rc22 (2026-10-25, runs/macro-rc22 - RESPIN 36: the cycle counter, the
  watchdog and Timer 3's PDM mode; rc21's recipe, GRT/DRT antenna repair
  5 iterations instead of 3): 79447 instances, 64.3%, 239441 um2 of
  standard cells, 1227K um of wire, global-route overflow 534, routing DRC
  / Magic DRC / LVS / antenna 0, hold +0.079, setup +4.36 nominal and -6.6
  at the slow max corner.  The first draw with the PDM as its own module
  (lisa_pdm.v) was stopped at 79 violations in the 25th detailed-route
  iteration (rc21: 6); with the PDM in Timer 3 the same point was 12, clean
  at 71, but one met3 antenna at 1.02 was left with 3 repair iterations
  (runs/macro-rc22-draw1; the re-run with 5 placed and routed the same).
  No cell on Calvin's 997 pixels (367 blockages).  Promoted 2026-10-25
  (Ken; the precheck left to the gds workflow): gds/, lef/, pnl/ are this
  run's.
* rc23 (2026-10-25, runs/macro-rc23 - RESPIN 37: the DDR instruction
  reads; rc22's recipe): 79368 instances, 64.6%, 240735 um2 of standard
  cells, 1244K um of wire, global-route overflow 830, routing DRC (clean at
  the 105th detailed-route iteration) / Magic DRC / LVS / antenna 0, hold
  +0.076, setup +5.24 nominal and -8.7 at the slow max corner: 183
  endpoints, all but the 16 of inst_r -> facc from op_ldk_r (lda (ix++)'s
  kfetch -> i_addr -> inst_stream's window subtract and hit -> k_ok ->
  d_ok, the core's enables; rc22 -6.6 on the same paths) - none in the
  QSPI.  No cell on Calvin's 997 pixels.  Promoted 2026-10-25 (Ken; the
  precheck left to the gds workflow): gds/, lef/, pnl/ are this run's.
* rc27 (2026-10-26, runs/macro-rc27 - RESPIN 38: the slow corner; rc23's
  recipe): 79242 instances, 64.7%, 1247K um of wire, routing DRC / Magic
  DRC / LVS / antenna 0, hold +0.079, setup +5.25 nominal, -1.41 at the
  slow max corner (9 endpoints: rem_stage_two -> d_ok -> ra), -0.43 nom_ss,
  +0.73 min_ss.  No cell on Calvin's 997 pixels.  Promoted 2026-10-26
  (Ken; the precheck left to the gds workflow): gds/, lef/, pnl/ are this
  run's.
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
