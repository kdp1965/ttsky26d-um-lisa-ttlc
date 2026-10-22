# test.py - tt_um_pettit_lisa in the testbench: the debugger over the UART, and a
# program from the flash model.
#   make                                 test_debugger, test_bringup (firmware.hex)
#   make IHX=../../lisa-tools/sdcc_test/test_core.ihx [CACHE=1] [TIMEOUT=clocks]
#                                        test_program: run it, expect ALL PASSED
import os
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from lisa import Lisa, Timeout, REG_STATUS, REG_LISA1_BASE, REG_PC, CHAR_CYCLES


def plusarg(name, default=None):
    return cocotb.plusargs.get(name, default)


async def start(dut):
    dut.ttlc_mode.value = 0
    dut.ttlc_in.value = 0
    dut.spi_map.value = 0
    lisa = Lisa(dut)
    await lisa.reset()
    return lisa


@cocotb.test(skip=plusarg('DEFAULT') is None)
async def test_autobaud(dut):
    """with ui_in[7] low the chip measures the debug UART's bit period from
    the first character's pulses (lisa_pydb sends CR, lisa_ide "+++" LF,
    the testbench LF: each has three single-bit pulses in a row) - any
    number of clocks since the second chip (TT07's generator counted in
    32s: 115200 baud at 50 MHz, 434 clocks, was not usable)"""
    lisa = await start(dut)
    for bitclks in (288, 300, 434, 109, 57, 32):
        await lisa.reset(autobaud=True, bitclks=bitclks)
        ver = await lisa.version()
        assert ver == 'lisav2.0', 'at %d clocks a bit: %r' % (bitclks, ver)
        await lisa.write_reg(REG_LISA1_BASE, 0x5a)
        assert await lisa.read_reg(REG_LISA1_BASE) == 0x5a, 'at %d clocks a bit' % bitclks
        dut._log.info('autobaud: %d clocks a bit ok' % bitclks)


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


async def ttlc_loopback(dut, lisa):
    """the TTLC program in the flash at 0x10000 copies the 48 inputs to the
    48 outputs through the testbench's I/O chains; check seven patterns"""
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
async def test_ttlc(dut):
    """the TTLC runs the loopback program (progs/ttlc/ttlc_loopback.asm, the
    slot format): the 48 outputs follow the 48 inputs (TT07 took 17 samples
    per scan, every input came back one position high)"""
    lisa = await start(dut)
    await ttlc_loopback(dut, lisa)


@cocotb.test(skip=plusarg('TTLC') is None)
async def test_ttlc_jump(dut):
    """the loopback through two subroutines, a skz over a jmp and nopf
    (progs/ttlc/ttlc_jump.asm, the image TTLC_IMAGE=progs/ttlc_jump_test.hex):
    jmp / rtn / skz / nopf in the slot format land right, or the copy breaks.
    The old RTL's jmp reloaded the PC on three clocks and pushed the stack
    three times (nothing had run one: the elevator and the loopback have none)"""
    if 'ttlc_jump' not in (plusarg('PROGRAM') or ''):
        dut._log.info('skipped: not the ttlc_jump image')
        return
    lisa = await start(dut)
    await ttlc_loopback(dut, lisa)


@cocotb.test(skip=plusarg('TTLC') is None)
async def test_ttlc_debug(dut):
    """the TTLC's breakpoints halt before their instruction and the step bit
    runs exactly one (TT07: a clock late, and the step bit did nothing)"""
    if 'ttlc_jump' in (plusarg('PROGRAM') or ''):
        dut._log.info('skipped: the breakpoint at 5 is for the loopback image')
        return
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)
    for a, v in ((0x1f, 0x0100), (0x1b, 0x3cff), (0x1c, 0x00a3)):
        await lisa.write_reg(a, v)
    dut.ttlc_mode.value = 1
    dut.ttlc_in.value = 0x0f0f0f0f0f0f
    await lisa.write_reg(0x48, 0x4000 | 5)                          # a breakpoint at 5 (group 1 slot 1; bit 14 = valid)
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


@cocotb.test(skip=plusarg('DEFAULT') is not None or plusarg('TTLC') is not None or plusarg('BANK') is not None or plusarg('OVERRUN') is not None
             or plusarg('SPIM') is not None)
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
        send = plusarg('SEND')
        prompt = plusarg('SEND_PROMPT')
        text = await lisa.run(timeout=timeout, send=send.encode().decode('unicode_escape') if send else None,
                              send_delay=int(plusarg('SEND_DELAY', 0)),
                              send_prompt=prompt.encode().decode('unicode_escape') if prompt else None)
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


@cocotb.test(skip=plusarg('SPIM') is None)
async def test_spi(dut):
    """+SPIM (make SPIM=1): the SPI master (RESPIN 29) on the mux-2 pins -
    SCLK uo[5], MOSI uo[6], CS0 uo[3] (all mux 2) and CS1 uo[7] (mux 0),
    MISO ui_in[2]: progs/spi.c against the two devices in tb.v, every
    divider it tries, both polarities, both phases, DONE and its request"""
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)
    await lisa.write_reg(0x1b, 0x2880)                              # uo[3], [5], [6] to mux 2
    dut.spi_map.value = 1
    dut.porta_in.value = 0
    b0, b1 = int(dut.spi_count0.value), int(dut.spi_count1.value)
    text = await lisa.run(timeout=400_000)
    c0, c1 = int(dut.spi_count0.value) - b0, int(dut.spi_count1.value) - b1
    dut._log.info('device 0 took %d bytes, device 1 %d' % (c0, c1))
    assert 'ALL PASSED' in text, 'the SPI test did not pass: %r' % text[-300:]
    assert (c0, c1) == (19, 18), 'bytes taken %d / %d, expected 19 / 18' % (c0, c1)


@cocotb.test(skip=plusarg('SPIM') is None)
async def test_spi_ttlc(dut):
    """+SPIM: the SPI master on the TTLC's pins (mux mode 3: SCLK uo[7],
    MOSI / CS0 / CS1 on the 595 chains' data uo[0..2]) while the TTLC runs
    its loopback: every transaction claims the pins.  The outputs never
    leave the pattern (a scan inside a transaction would shift the SPI's
    levels into the chains), no TTLC shift clock falls inside a transaction,
    the program saw the TTLC wait, and the loopback still follows its
    inputs after"""
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)
    for a, v in ((0x1f, 0x0100), (0x1b, 0xfcff), (0x1c, 0x00a3)):   # TTLC base, uo[0-3], [5-7] to select 3, shift clk/4
        await lisa.write_reg(a, v)
    pat = 0x123456789abc
    dut.ttlc_in.value = pat
    dut.ttlc_mode.value = 1
    dut.spi_map.value = 2
    dut.porta_in.value = 1
    await lisa.write_reg(0x40, 1)                                    # the TTLC runs
    await ClockCycles(dut.clk, 20000)
    assert int(dut.ttlc_out.value) == pat, 'the loopback is not running'
    differ = int(dut.ttlc_differ.value)
    b0, b1 = int(dut.spi_count0.value), int(dut.spi_count1.value)   # the device models count from the start
    text = await lisa.run(timeout=400_000)
    differ = int(dut.ttlc_differ.value) - differ
    c0, c1 = int(dut.spi_count0.value) - b0, int(dut.spi_count1.value) - b1
    col = int(dut.spi_collide.value)
    dut._log.info('device 0 took %d bytes, device 1 %d; %d TTLC clocks inside transactions' % (c0, c1, col))
    assert 'ALL PASSED' in text, 'the SPI test did not pass: %r' % text[-300:]
    assert differ == 0, 'the TTLC outputs left the inputs for %d clocks during the SPI transfers' % differ
    assert col == 0, '%d TTLC shift clocks inside SPI transactions' % col
    assert (c0, c1) == (91, 90), 'bytes taken %d / %d, expected 91 / 90' % (c0, c1)
    # the TTLC still scans (the program has the UART now: no debugger reads)
    for p in (0xaaaaaaaaaaaa, 0x5a5a5a5a5a5a):
        dut.ttlc_in.value = p
        await ClockCycles(dut.clk, 40000)
        assert int(dut.ttlc_out.value) == p, 'outputs %012x for inputs %012x after the SPI' % (int(dut.ttlc_out.value), p)


@cocotb.test(skip=plusarg('OVERRUN') is None)
async def test_uart_overrun(dut):
    """+OVERRUN (make OVERRUN=1): progs/uartov.hex - twelve characters into
    the 8-byte receive FIFO while the program is not reading: status bit 2
    (RESPIN 14) is set, eight bytes come out, the flag clears once the FIFO
    has been read empty, and the echo works after"""
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)
    await lisa.run(timeout=400 * CHAR_CYCLES, stop_at=('ready\n',))
    for c in '0123456789AB':
        await lisa.tx(ord(c))
    # collect the report without resetting the core (run() would)
    text = ''
    while 'ALL PASSED' not in text and 'SOME FAILED' not in text:
        v = await lisa.rx(4000 * CHAR_CYCLES)
        assert v is not None, 'no report: %r' % text
        text += chr(v) if 32 <= v < 127 or v in (10, 13) else '?'
    for line in text.split('\n'):
        if line.strip():
            dut._log.info('[LISA] %s' % line.strip())
    assert 'ALL PASSED' in text, text
    await lisa.tx(ord('Z'))
    v = await lisa.rx(200 * CHAR_CYCLES)
    while v in (10, 13):                    # the end of the report's last line
        v = await lisa.rx(200 * CHAR_CYCLES)
    assert v == ord('Z'), 'echo after the overrun: %r' % v


@cocotb.test(skip=plusarg('BANK') is None)
async def test_bank(dut):
    """+BANK (make BANK=1): progs/bank_test.hex - the bank registers (RESPIN 22):
    calls into code banks 1-3 at word 0x4000, one address in three data banks
    through the cache, bank 0 as the lower half, evictions between banks, the
    stack in bank 2; the data cache on (the banks are PSRAM)"""
    lisa = await start(dut)
    await lisa.setup(cache=True, quad=plusarg('SPI') is None)
    text = await lisa.run(timeout=int(plusarg('TIMEOUT', 2_000_000)))
    assert 'ALL PASSED' in text, 'the bank test did not pass: %r' % text[-300:]


@cocotb.test(skip=plusarg('TTLCTRACE') is None)
async def test_ttlc_trace(dut):
    """+TTLCTRACE[=clocks]: run the TTLC program in +FIRMWARE (at flash byte
    0x10000) and log every clock the TTLC's PC, its instruction word and the
    core's JMP / RTN change - for working out the fetch pipeline (icarus:
    Verilator does not expose the internal signals)"""
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)
    for a, v in ((0x1f, 0x0100), (0x1b, 0x3cff), (0x1c, 0x00a3)):
        await lisa.write_reg(a, v)
    dut.ttlc_mode.value = 1
    dut.ttlc_in.value = int(plusarg('TTLCIN', '0'), 0)
    await lisa.write_reg(0x40, 1)
    t = dut.lisa
    last = None
    for clk in range(int(plusarg('TTLCTRACE', '3000') or 3000)):
        await RisingEdge(dut.clk)
        try:
            cur = (int(t.mc14500_pc.value), int(t.ttlc_inst.value), int(t.ttlc_i_ready.value),
                   int(t.i_mc14500b.r_inst.value), int(t.JMP.value), int(t.RTN.value), int(t.FLAG_F.value),
                   int(t.mc14500_run.value), int(t.mc14500_stack[0].value))
        except ValueError:
            continue
        if cur != last:
            dut._log.info('clk %5d pc %04x inst %04x rdy %d r_inst %x jmp %d rtn %d F %d run %d stk0 %04x' % ((clk,) + cur))
            last = cur
    out = int(dut.ttlc_out.value)
    dut._log.info('outputs %012x' % out)
