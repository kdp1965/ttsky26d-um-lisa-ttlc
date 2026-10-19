# The testbenches

Three cocotb testbenches, Verilator where it is installed (5.036 or later;
on this Mac cocotb's libraries are x86_64 builds and the Makefiles say so),
icarus otherwise or with `make SIM=icarus` (what CI runs).

## `test/` - the chip

`tb.v` wires `tt_um_lisa` to a SPI flash model (`spiflash.v`, the image from
`+FIRMWARE=<hex>`), a QSPI RAM model on CE1 (`psram.v`), a UART on the
debug port with a fixed baud divider, and the TTLC's three 74HC595 and three
74HC165 chains (`ttlc_chains`). `lisa.py` is the debugger over that UART:
the `rXX` / `wXXYYYY` / `v` / `t` / `l` protocol, the Commander's register
setup (`setup()`), `run()` of a program with its console text.

```sh
make                          # test_autobaud (the debug UART trained at six bit periods), test_debugger, test_bringup (progs/hello.hex), test_uart_burst
make TTLC=1                   # the TTLC loopback through the chains, its breakpoints and step
make TTLC=1 TTLC_IMAGE=$PWD/progs/ttlc_jump_test.hex   # the loopback through jmp / rtn / skz / nopf
make SIM=icarus TTLC=1 TTLCTRACE=6000 TESTCASE=test_ttlc_trace [TTLCIN=0x3]   # log the TTLC's fetch per clock
make BANK=1                   # the bank registers (RESPIN 22): progs/bank.c with routines in banks 1-3, the cache on
make OVERRUN=1                # the UART receive FIFO's overrun flag (RESPIN 14): progs/uartov.c
make IHX=../../lisa-tools/sdcc_test/test_core.ihx [CACHE=1] [TIMEOUT=clocks]
./run_suite.sh chip REV2=1    # the SDCC suite's self-checking programs (the
                              # *_rev2.ihx of `make check REV2=1`: this RTL's
                              # stack convention; without REV2=1 the TT07 build)
./run_suite.sh chip REV2=1 CACHE=1   # the ones that need the 32K data space
                              # (test_bigframe, test_ptroff; with the TT07
                              # build also the cache tests)
make SIM=icarus               # what CI runs
```

`TIMEOUT` is clocks of console silence (a program that computes for long
without printing needs more). `STATS=1` counts the fetch: the clocks per
instruction, the clocks the core waited for one, the streaming fetch's
bursts and words (`fetch: ...` in the log). `DUMP=1` writes `tb.vcd` (FST
under Verilator, built for tracing; `fst2vcd` converts it). `TRACE=<file>`
writes an instruction trace to compare with lisa_sim's (`-t`, or `trace on`):
an `I` line per instruction (clock, bank:PC, word, A, IX, SP, RA, cond, Z/C,
amode, the amode shadow, ie, IA, the data cache's valid/dirty lines), `D`/`P`
lines per data and peripheral access, `C` per code-bank write and `X` per
interrupt entry; `TRACE_PC=<hex> [TRACE_CB=<bank>]` starts it at the first
fetch of that window address, `TRACE_COUNT=<n>` stops it after n
instructions and `TRACE_FINISH=1` ends the run there (the C and X lines are
written from reset).  NuttX's non-boot (RESPIN 24) was found by tracing both
from reset and diffing: they agreed to the first timer interrupt.
`SEND='text'` types to the program (escapes as in Python), after
`SEND_DELAY=<clocks>` if given, so a shell gets its prompt up first; the
trace's `Q` lines log the writes of INT_ENABLE, INT_STATUS and UART_INT_EN
(RESPIN 25 showed in them: the enable written once and read back 0).

## `test/core/` - the core

`tb_core.v` is the core with the chip's data path - the registered data bus,
`data_cache8.v`, the RAM32 (write-first like the DFFRAM macro), the QSPI
sequencer with the RAM model, `lisa_periph` - but the instructions straight
from an array and the debug port driven from Python (`test_core.py`,
`Core`). Programs run at a few clocks per instruction: test_core takes
45K clocks, 0.4 s under Verilator.

```sh
make IHX=../progs/reti.ihx                 # a program: expect ALL PASSED
make IHX=../progs/cache14.ihx CACHE=1      # the data cache on, 32K through the RAM model
make IHX=../progs/dbg.ihx                  # the debugger tests on dbg's loop
make IHX=../progs/irq3.ihx TRACEPC=ef TRACEWIN=e1   # a trace of the handler's accesses
ILAT=1                                     # one clock of fetch latency instead of none
```

## `test/fops/`

`fadd` and `fmul` as the core wires them, against `bf16.py`, an exact
bfloat16 reference (nearest even and toward zero): 7100 cases.

## `test/progs/`

The probe programs, each for an item of `RESPIN.md`: `hello` (the
bring-up image), `alu2` (the ALU flags against the compiler's arithmetic),
`reti`, `div16`, `cache14`, `swap`, `dbg` (a loop for the debugger tests),
`irq3` (test_irq with its check 3 values printed), and `ttlc/` (the TTLC
programs: the loopback and the jump test, assembled by `ttlc/mc14500_as.py`
into the slot format of `ttlc_fetch.v` - 12-bit instructions, four to
three words, RESPIN.md item 19). `make` there rebuilds them with `sdcc -mlisa --rev2` from
lisa-tools (the second chip's stack convention, SP at the top byte, since
2026-10-17: a TT07 build's frames are one byte off on this RTL); the `.hex`
images are committed so the testbenches run without it.
`ihx2hex.py` converts Intel HEX, `hexcat.py` places images in one flash.
