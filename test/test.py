# test.py - tt_um_lisa in the testbench: the debugger over the UART, and a
# program from the flash model.
#   make                                 test_debugger, test_bringup (firmware.hex)
#   make IHX=../../lisa-tools/sdcc_test/test_core.ihx [CACHE=1] [TIMEOUT=clocks]
#                                        test_program: run it, expect ALL PASSED
import os
import cocotb
from cocotb.triggers import ClockCycles

from lisa import Lisa, Timeout, REG_STATUS, REG_LISA1_BASE, REG_PC, CHAR_CYCLES


def plusarg(name, default=None):
    return cocotb.plusargs.get(name, default)


async def start(dut):
    dut.ttlc_mode.value = 0
    dut.ttlc_in.value = 0
    lisa = Lisa(dut)
    await lisa.reset()
    return lisa


@cocotb.test(skip=plusarg('DEFAULT') is None)
async def test_debugger(dut):
    """the debugger answers: version, register write / read back, halted at reset"""
    lisa = await start(dut)
    ver = await lisa.version()
    dut._log.info('version: %s' % ver)
    assert ver == 'lisav2.0', ver   # TT07 reports lisav1.2; the major digit is the chip's revision
    assert (await lisa.read_reg(REG_STATUS)) & 1 == 1, 'the core is not halted after reset'
    await lisa.write_reg(REG_LISA1_BASE, 0x1234)
    await lisa.check_reg(REG_LISA1_BASE, 0x1234)
    await lisa.write_reg(REG_LISA1_BASE, 0)
    await lisa.write_reg(REG_PC, 0x0123)
    await lisa.check_reg(REG_PC, 0x0123)


@cocotb.test(skip=plusarg('DEFAULT') is None)
async def test_bringup(dut):
    """progs/hello.hex prints its banner from the flash and echoes a character"""
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)
    text = await lisa.run(timeout=400 * CHAR_CYCLES, stop_at=('ready\n',))
    assert 'hello from sdcc' in text, text
    await lisa.tx(ord('?'))
    assert (await lisa.rx(100 * CHAR_CYCLES)) == ord('?'), 'no echo'


@cocotb.test(skip=plusarg('DEFAULT') is None)
async def test_uart_burst(dut):
    """a burst of characters to hello's echo loop: the receive FIFO keeps them
    (TT07 held one byte and lost every other character of a burst)"""
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)
    await lisa.run(timeout=400 * CHAR_CYCLES, stop_at=('ready\n',))
    burst = 'burst-of-8'
    for c in burst:
        await lisa.tx(ord(c))
    got = ''
    for _ in burst:
        v = await lisa.rx(200 * CHAR_CYCLES)
        if v is None:
            break
        got += chr(v)
    assert got == burst, 'echoed %r' % got


@cocotb.test(skip=plusarg('TTLC') is None)
async def test_ttlc(dut):
    """the TTLC runs the loopback program from the flash at 0x10000 with the
    I/O chains of the testbench: the 48 outputs follow the 48 inputs (TT07
    took 17 samples per scan, every input came back one position high)"""
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)
    for a, v in ((0x1f, 0x0100), (0x1b, 0x3cff), (0x1c, 0x00a3)):   # TTLC base, uo_out to the TTLC, shift clock clk/4
        await lisa.write_reg(a, v)
    dut.ttlc_in.value = 0
    dut.ttlc_mode.value = 1
    await lisa.write_reg(0x40, 1)                                    # run
    await ClockCycles(dut.clk, 20000)
    st = await lisa.read_reg(0x40)
    pc = await lisa.read_reg(0x41)
    dut._log.info('TTLC status 0x%04x pc 0x%03x' % (st, pc))
    assert st & 1, 'the TTLC is not running'
    for pat in (0x123456789abc, 1, 0x800000000000, 0xaaaaaaaaaaaa, 0xffffffffffff, 0, 0x5a5a5a5a5a5a):
        dut.ttlc_in.value = pat
        await ClockCycles(dut.clk, 40000)
        got = int(dut.ttlc_out.value)
        dut._log.info('inputs %012x -> outputs %012x' % (pat, got))
        assert got == pat, 'outputs %012x for inputs %012x' % (got, pat)
    await lisa.write_reg(0x40, 0)


@cocotb.test(skip=plusarg('TTLC') is None)
async def test_ttlc_debug(dut):
    """the TTLC's breakpoints halt before their instruction and the step bit
    runs exactly one (TT07: a clock late, and the step bit did nothing)"""
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)
    for a, v in ((0x1f, 0x0100), (0x1b, 0x3cff), (0x1c, 0x00a3)):
        await lisa.write_reg(a, v)
    dut.ttlc_mode.value = 1
    dut.ttlc_in.value = 0x0f0f0f0f0f0f
    await lisa.write_reg(0x48, 0x1000 | 5)                          # a breakpoint at 5
    await lisa.write_reg(0x40, 1)
    await ClockCycles(dut.clk, 20000)
    st, pc = await lisa.read_reg(0x40), await lisa.read_reg(0x41)
    assert not (st & 1) and pc == 5, 'status 0x%04x pc %d: not halted at the breakpoint' % (st, pc)
    await lisa.write_reg(0x40, 1)                                    # run on: the breakpoint is passed...
    await ClockCycles(dut.clk, 20000)
    st, pc = await lisa.read_reg(0x40), await lisa.read_reg(0x41)
    assert not (st & 1) and pc == 5, 'status 0x%04x pc %d: not back at the breakpoint after a loop' % (st, pc)
    await lisa.write_reg(0x48, 0)
    for expect in (6, 7, 8):                                         # ... and the step bit: one instruction each
        await lisa.write_reg(0x40, 2)
        await ClockCycles(dut.clk, 2000)
        st, pc = await lisa.read_reg(0x40), await lisa.read_reg(0x41)
        assert not (st & 1) and pc == expect, 'status 0x%04x pc %d after a step, expected %d' % (st, pc, expect)
    # step round the loop: the nopf at its end resets the PC under the step
    # (TT07 lost the PC change of a stepped jmp / rtn / nopf)
    last = 8
    wrapped = False
    for _ in range(120):
        await lisa.write_reg(0x40, 2)
        await ClockCycles(dut.clk, 2000)
        pc = await lisa.read_reg(0x41)
        if pc < last:
            assert pc == 0, 'the nopf at %d landed on %d' % (last, pc)
            wrapped = True
            break
        assert pc == last + 1, 'pc %d after a step from %d' % (pc, last)
        last = pc
    assert wrapped, 'no return to 0 within 120 steps'
    await lisa.write_reg(0x40, 1)
    await ClockCycles(dut.clk, 40000)
    assert int(dut.ttlc_out.value) == 0x0f0f0f0f0f0f, 'the loopback did not resume'


@cocotb.test(skip=plusarg('DEFAULT') is not None or plusarg('TTLC') is not None)
async def test_program(dut):
    """+FIRMWARE=<hex>: run it (the data cache on with +CACHE) and expect ALL PASSED;
    +STATS counts the fetch clocks"""
    lisa = await start(dut)
    cache = plusarg('CACHE') is not None
    timeout = int(plusarg('TIMEOUT', 2_000_000))
    await lisa.setup(cache=cache, quad=plusarg('SPI') is None)
    dut._log.info('running %s with the data cache %s' % (plusarg('PROGRAM', plusarg('FIRMWARE')), 'on' if cache else 'off'))
    stats = plusarg('STATS') is not None
    counters = ('st_clocks', 'st_insts', 'st_wait', 'st_xfers', 'st_words')
    before = [int(getattr(dut, c).value) for c in counters] if stats else None
    try:
        text = await lisa.run(timeout=timeout)
    finally:
        if stats:
            # the counters are in tb.v; between the resume and the last line
            # of output (a finished program spins, but only until run returns)
            clocks, insts, wait, xfers, words = [int(getattr(dut, c).value) - b for c, b in zip(counters, before)]
            dut._log.info('fetch: %d clocks, %d instructions (%.1f clocks each), %d clocks waiting for one (%.0f%%), '
                          '%d QSPI transfers delivering %d words (%.1f each)'
                          % (clocks, insts, clocks / max(1, insts), wait, 100.0 * wait / max(1, clocks),
                             xfers, words, words / max(1, xfers)))
    assert 'ALL PASSED' in text, 'the program did not pass: %r' % text[-200:]
