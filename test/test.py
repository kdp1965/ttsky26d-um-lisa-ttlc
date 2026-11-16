# test.py - tt_um_pettit_lisa in the testbench: the debugger over the UART, and a
# program from the flash model.
#   make                                 test_debugger, test_bringup (firmware.hex)
#   make IHX=../../lisa-tools/sdcc_test/test_core.ihx [CACHE=1] [TIMEOUT=clocks]
#                                        test_program: run it, expect ALL PASSED
import os
import cocotb
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from lisa import Lisa, Timeout, REG_STATUS, REG_LISA1_BASE, REG_PC, CHAR_CYCLES, REG_CS_CFG, REG_DBG_ADDR_L, REG_DBG_ADDR_H


def plusarg(name, default=None):
    return cocotb.plusargs.get(name, default)


async def start(dut):
    dut.ttlc_mode.value = 0
    dut.ttlc_in.value = 0
    dut.spi_map.value = 0
    dut.ttlc_watch.value = 0
    dut.cap_period.value = 0
    dut.ws_arm.value = 0
    dut.m3.value = 0
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
    for _ in range(300):                 # the loopback is 98 steps, the storage loopback 194
        await lisa.write_reg(0x40, 2)
        await ClockCycles(dut.clk, 2000)
        pc = await lisa.read_reg(0x41)
        if pc < last:
            assert pc == 0, 'the nopf at %d landed on %d' % (last, pc)
            wrapped = True
            break
        assert pc == last + 1, 'pc %d after a step from %d' % (pc, last)
        last = pc
    assert wrapped, 'no return to 0 within 300 steps'
    await lisa.write_reg(0x40, 1)
    await ClockCycles(dut.clk, 40000)
    assert int(dut.ttlc_out.value) == 0x0f0f0f0f0f0f, 'the loopback did not resume'


@cocotb.test(skip=plusarg('DEFAULT') is not None or plusarg('TTLC') is not None or plusarg('BANK') is not None or plusarg('OVERRUN') is not None
             or plusarg('SPIM') is not None or plusarg('TTLCIO') is not None or plusarg('TIMER3') is not None
             or plusarg('WS2812') is not None or plusarg('WSDMA') is not None or plusarg('I2C') is not None
             or plusarg('MISC36') is not None or plusarg('DDRSWEEP') is not None
             or plusarg('MISC40') is not None or plusarg('PLC') is not None)
async def test_program(dut):
    """+FIRMWARE=<hex>: run it (the data cache on with +CACHE) and expect ALL PASSED;
    +STATS counts the fetch clocks"""
    lisa = await start(dut)
    cache = plusarg('CACHE') is not None
    timeout = int(plusarg('TIMEOUT', 2_000_000))
    m3 = plusarg('M3') is not None
    dut.m3.value = int(m3)
    await lisa.setup(cache=cache, quad=plusarg('SPI') is None, m3=m3)
    dut._log.info('running %s with the data cache %s%s' % (plusarg('PROGRAM', plusarg('FIRMWARE')), 'on' if cache else 'off',
                                                          ', io mux mode 3' if m3 else ''))
    stats = plusarg('STATS') is not None
    counters = ('st_clocks', 'st_insts', 'st_wait', 'st_xfers', 'st_words')
    toggle = int(plusarg('DDR_TOGGLE', 0))
    if toggle:
        # +DDR_TOGGLE=<clocks> (RESPIN 37): 0x17's DDR bit on CS0 and the
        # seamless bit flipped every that many clocks while the program runs
        # from the flash - a burst open at the change goes on as it began,
        # the next one takes the new setting
        async def flip():
            regs = dut.lisa.i_debug_regs
            n = 0
            while True:
                await Timer(toggle * 20 + 7, 'ns')     # not on the clock's edges: an extra waiter on
                n += 1                                  # them broke the bench UART's read strobe
                what = plusarg('DDR_TOGGLE_ONLY', 'both')       # ddr, seamless, both; none rewrites 0x17's bits unchanged
                if what in ('ddr', 'both'):
                    regs.ddr_sel.value = n & 1
                if what in ('seamless', 'both'):
                    regs.ddr_seamless.value = ((n >> 1) if what == 'both' else n) & 1
                if what == 'idle':
                    continue
                if what == 'none':
                    regs.ddr_sel.value = int(regs.ddr_sel.value)
        cocotb.start_soon(flip())
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


TTLCIO_INPUTS = 0x0123456789ab
TTLCIO_OUT1 = 0x665544332211
TTLCIO_OUT2 = 0xf00f5aa53cc3


async def ttlcio_setup(dut, lisa, porta):
    """mux mode 3 on the TTLC's pins (uo[0-3], [5-7]; uo[4] the UART),
    the shift clock clk/4, the TTLC program at flash byte 0x10000, the
    inputs on the 165 chains"""
    await lisa.setup(cache=False, quad=True)
    for a, v in ((0x1f, 0x0100), (0x1b, 0xfcff), (0x1c, 0x00a3)):
        await lisa.write_reg(a, v)
    dut.ttlc_in.value = TTLCIO_INPUTS
    dut.ttlc_mode.value = 1
    dut.porta_in.value = porta


@cocotb.test(skip=plusarg('TTLCIO') is None)
async def test_ttlcio(dut):
    """+TTLCIO (make TTLCIO=1): progs/ttlcio.c with the ICU halted (the
    reset state) - the core reads and writes the TTLC's I/O vector a byte at
    a time and scans the chains itself: the inputs it captured are the
    testbench's, and the outputs it left are on the 595 chains"""
    lisa = await start(dut)
    await ttlcio_setup(dut, lisa, 0)
    text = await lisa.run(timeout=600_000)
    assert 'ALL PASSED' in text, 'the TTLC I/O test did not pass: %r' % text[-300:]
    out = int(dut.ttlc_out.value)
    assert out == TTLCIO_OUT2, 'the chains hold %012x, the core wrote %012x' % (out, TTLCIO_OUT2)


@cocotb.test(skip=plusarg('TTLCIO') is None)
async def test_ttlcio_run(dut):
    """+TTLCIO: progs/ttlcio.c with the ICU running its loopback - the core
    watches the scans and the copied outputs, then holds the ICU with the
    SPI master's claim, puts its own outputs on the chains with a scan of
    its own (whenever the outputs are not the inputs they are the core's),
    and after the release the loopback copies the inputs again"""
    lisa = await start(dut)
    await ttlcio_setup(dut, lisa, 1)
    await lisa.write_reg(0x40, 1)                                    # the TTLC runs
    await ClockCycles(dut.clk, 20000)
    assert int(dut.ttlc_out.value) == TTLCIO_INPUTS, 'the loopback is not running'
    differ = int(dut.ttlc_differ.value)
    dut.ttlc_watch.value = TTLCIO_OUT1
    match = int(dut.ttlc_match.value)
    text = await lisa.run(timeout=800_000)
    differ = int(dut.ttlc_differ.value) - differ
    match = int(dut.ttlc_match.value) - match
    dut._log.info('the outputs differed from the inputs for %d clocks, held OUT1 for %d' % (differ, match))
    assert 'ALL PASSED' in text, 'the TTLC I/O test did not pass: %r' % text[-300:]
    # whenever the outputs left the inputs they were the core's OUT1: put on
    # the chains by its scan during the hold (the data pins the scan's, not
    # the SPI master's), not by the ICU's held scan after the release only
    assert differ > 0 and match == differ, \
        'the outputs left the inputs for %d clocks, %d of them with the core\'s %012x' % (differ, match, TTLCIO_OUT1)
    await ClockCycles(dut.clk, 20000)
    assert int(dut.ttlc_out.value) == TTLCIO_INPUTS, 'the loopback did not resume: %012x' % int(dut.ttlc_out.value)


@cocotb.test(skip=plusarg('TIMER3') is None)
async def test_timer3(dut):
    """+TIMER3 (make TIMER3=1): progs/timer3.c - Timer 3 (RESPIN 32) with a
    square wave of 2 x 3000 clocks on its capture inputs (ui_in[5:4]); after
    the run the program leaves PWM0 at 25% and PWM1 at 75% of a 100-clock
    period on uo[1] / uo[2] (mux 2), measured here over 20000 clocks"""
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)
    await lisa.write_reg(0x1b, 0x0028)                               # uo[1], uo[2] to mux 2
    dut.cap_period.value = 3000
    text = await lisa.run(timeout=600_000)
    assert 'ALL PASSED' in text, 'the Timer 3 test did not pass: %r' % text[-300:]
    h0, h1, c0 = int(dut.pwm_high0.value), int(dut.pwm_high1.value), int(dut.clocks.value)
    await ClockCycles(dut.clk, 20000)
    h0, h1 = int(dut.pwm_high0.value) - h0, int(dut.pwm_high1.value) - h1
    n = int(dut.clocks.value) - c0
    dut._log.info('PWM0 high %d of %d clocks (%.1f%%), PWM1 %d (%.1f%%)' % (h0, n, 100.0 * h0 / n, h1, 100.0 * h1 / n))
    assert abs(h0 / n - 0.25) < 0.01 and abs(h1 / n - 0.75) < 0.01, 'PWM duty %.3f / %.3f, expected 0.25 / 0.75' % (h0 / n, h1 / n)


def ws_hash(pixels):
    h = 0
    for g, r, b in pixels:
        h = ((h * 33) ^ ((g << 16) | (r << 8) | b)) & 0xFFFFFFFF
    return h


@cocotb.test(skip=plusarg('WS2812') is None)
async def test_ws2812(dut):
    """+WS2812 (make WS2812=1): progs/ws2812.c - the WS2812B driver (RESPIN
    33) on mux 3's TTLC pins, the TTLC halted: frame 1 (8 pixels) and frame
    3 (2 pixels, the second late) on uo[1], frame 2 (3 pixels) on uo[2],
    decoded by tb.v's receivers - every pixel and its order (the hash), the
    frames, no malformed pulse, and no edge on the pins not selected"""
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)
    await lisa.write_reg(0x1b, 0x3c3f)                               # uo[0-2], [5], [6] to mux 3
    dut.ws_arm.value = 1
    text = await lisa.run(timeout=1_200_000)
    assert 'ALL PASSED' in text, 'the WS2812B test did not pass: %r' % text[-300:]
    await ClockCycles(dut.clk, 20000)                                # the last frame's reset
    f1 = [((i << 4) | 1, 0x80 ^ i, (0xC3 + i) & 0xFF) for i in range(8)]
    f2 = [(0x10 + i, 0x20 + i, 0x30 + i) for i in range(3)]
    f3 = [(0x5A, 0xA5, 0x0F), (0xF0, 0x3C, 0xC3)]
    got = (int(dut.ws_count1.value), int(dut.ws_hash1.value), int(dut.ws_frames1.value),
           int(dut.ws_count2.value), int(dut.ws_hash2.value), int(dut.ws_frames2.value),
           int(dut.ws_bad.value), int(dut.ws_other.value))
    dut._log.info('uo[1]: %d pixels, hash %08x, %d frames; uo[2]: %d pixels, hash %08x, %d frames; '
                  '%d bad pulses, %d edges on idle pins' % got)
    assert got == (10, ws_hash(f1 + f3), 2, 3, ws_hash(f2), 1, 0, 0), \
        'expected uo[1] 10 pixels %08x 2 frames, uo[2] 3 pixels %08x 1 frame, none bad or stray' % (ws_hash(f1 + f3), ws_hash(f2))


@cocotb.test(skip=plusarg('WSDMA') is None)
async def test_wsdma(dut):
    """+WSDMA (make WSDMA=1): progs/wsdma.c - the WS2812B driver's DMA
    (RESPIN 35), the data cache on: frame A (7 pixels written just before
    START: the flush) and frame C (3 pixels, REPEAT: two or more frames) on
    uo[1], frame B (100 pixels, 300 bytes, the core thrashing the cache
    meanwhile) on uo[2]; every pixel and its order, the frames, nothing bad
    or stray"""
    lisa = await start(dut)
    await lisa.setup(cache=True, quad=True)
    await lisa.write_reg(0x1b, 0x3c3f)                               # uo[0-2], [5], [6] to mux 3
    dut.ws_arm.value = 1
    try:
        text = await lisa.run(timeout=2_000_000)
    except Exception:
        text = None
    await ClockCycles(dut.clk, 20000)
    fa = [((i * 17 + 1) & 0xFF, 0x40 ^ i, 0xA0 + i) for i in range(7)]
    fb = [(i, 0xFF - i, i ^ 0x55) for i in range(100)]
    fc = [(0x11 * (i + 1), 0x22, 0x33 + i) for i in range(3)]
    got = (int(dut.ws_count1.value), int(dut.ws_hash1.value), int(dut.ws_frames1.value),
           int(dut.ws_count2.value), int(dut.ws_hash2.value), int(dut.ws_frames2.value),
           int(dut.ws_bad.value), int(dut.ws_other.value))
    dut._log.info('uo[1]: %d pixels, hash %08x, %d frames; uo[2]: %d pixels, hash %08x, %d frames; '
                  '%d bad pulses, %d edges on idle pins' % got)
    assert text is not None and 'ALL PASSED' in text, 'the WS2812B DMA test did not pass: %r' % text
    k = got[2] - 1                                                   # frame C's repeats
    assert k >= 2, 'frame C ran %d times, expected at least 2' % k
    assert got == (7 + 3 * k, ws_hash(fa + fc * k), 1 + k, 100, ws_hash(fb), 1, 0, 0), \
        'expected uo[1] %d pixels %08x, uo[2] 100 pixels %08x 1 frame, none bad or stray' % (
            7 + 3 * k, ws_hash(fa + fc * k), ws_hash(fb))


@cocotb.test(skip=plusarg('MISC36') is None)
async def test_misc36(dut):
    """+MISC36 (make MISC36=1): progs/misc36.c - RESPIN 36: the cycle
    counter; the watchdog kept off by kicks, then firing (the program
    restarts and finds WDRST); the two PDM channels left at 64 and 192,
    (Timer 3's channels in PDM mode) - their duty on uo[1] / uo[2] (mux 2)
    measured here: 25% and 75%"""
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)
    await lisa.write_reg(0x1b, 0x0028)                               # uo[1], uo[2] to mux 2
    text = await lisa.run(timeout=1_500_000)
    assert 'ALL PASSED' in text and 'FAIL' not in text and 'watchdog reset' in text, \
        'the RESPIN 36 test did not pass: %r' % text[-400:]
    h0, h1, c0 = int(dut.pwm_high0.value), int(dut.pwm_high1.value), int(dut.clocks.value)
    await ClockCycles(dut.clk, 25600)
    h0, h1 = int(dut.pwm_high0.value) - h0, int(dut.pwm_high1.value) - h1
    n = int(dut.clocks.value) - c0
    dut._log.info('PDM0 high %d of %d clocks (%.2f%%), PDM1 %d (%.2f%%)' % (h0, n, 100.0 * h0 / n, h1, 100.0 * h1 / n))
    assert abs(h0 / n - 0.25) < 0.005 and abs(h1 / n - 0.75) < 0.005, 'PDM density %.4f / %.4f, expected 0.25 / 0.75' % (h0 / n, h1 / n)


@cocotb.test(skip=plusarg('DDRSWEEP') is None)
async def test_ddr_sweep(dut):
    """+DDRSWEEP (make DDRSWEEP=1 [SPI_TCO=ns] [DTR_LAUNCH=1]): RESPIN 37's
    capture point found as a host would - the debugger reads 32 words of the
    flash in SDR, then with 0x17's DDR bit on at each of the 8 capture
    points (its single-word reads are EDh then too), and the points that
    read the same words pass; hello then runs from the flash in DDR at the
    middle one; after a reset 0x17 is SDR again"""
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)

    async def words():
        await lisa.write_reg(REG_DBG_ADDR_L, 0)
        await lisa.write_reg(REG_DBG_ADDR_H, 0)
        return [await lisa.read_reg(0x20) for _ in range(32)]

    ref = await words()
    good = []
    for cap in range(8):
        await lisa.write_reg(REG_CS_CFG, 0x0047 | cap << 9 | 7 << 12)
        got = await words()
        bad = sum(1 for a, b in zip(ref, got) if a != b)
        dut._log.info('DDR capture point %d: %s' % (cap, 'ok' if not bad else '%d of 32 words wrong (%04x for %04x)'
                      % (bad, next(b for a, b in zip(ref, got) if a != b), next(a for a, b in zip(ref, got) if a != b))))
        if not bad:
            good.append(cap)
    assert good, 'no capture point reads the flash'
    assert good == list(range(good[0], good[-1] + 1)), 'the passing points are not contiguous: %r' % good
    cap = good[len(good) // 2]
    dut._log.info('passing points %r: running hello in DDR at %d' % (good, cap))
    await lisa.write_reg(REG_CS_CFG, 0x0047 | cap << 9 | 7 << 12)
    text = await lisa.run(timeout=400 * CHAR_CYCLES, stop_at=('ready\n',))
    assert 'hello from sdcc' in text, text
    await lisa.reset()
    assert await lisa.read_reg(REG_CS_CFG) == 0x7205, 'not SDR after a reset'
    await lisa.setup(cache=False, quad=True)
    assert await words() == ref, 'SDR reads after DDR differ'


@cocotb.test(skip=plusarg('I2C') is None)
async def test_i2c(dut):
    """+I2C (make I2C=1): progs/i2c.c in io mux mode 3 (the custom Pmod's CE
    latch, the data cache on through it) with the I2C master on uio[4] /
    uio[5] at 400 kHz: a probe of 0x3D (not acknowledged), an SSD1309
    command transaction and a data one to tb.v's slave at 0x3C - its bytes,
    their order (the hash), two transactions, one NAK"""
    lisa = await start(dut)
    dut.m3.value = 1
    await lisa.setup(cache=True, quad=True, m3=True)
    text = await lisa.run(timeout=2_000_000)
    assert 'ALL PASSED' in text, 'the I2C test did not pass: %r' % text[-300:]
    cmds = [0x00, 0xAE, 0xD5, 0xA0, 0xA8, 0x3F, 0xD3, 0x00, 0x40, 0xA1, 0xC8, 0xDA, 0x12,
            0x81, 0x6F, 0xD9, 0xD3, 0xDB, 0x34, 0xA4, 0xA6, 0x20, 0x00, 0xAF]
    data = [0x40] + [(i * 37 + 5) & 0xFF for i in range(16)]
    h = 0
    for b in cmds + data:
        h = ((h * 33) ^ b) & 0xFFFFFFFF
    got = (int(dut.i2c_count.value), int(dut.i2c_hash.value), int(dut.i2c_txns.value), int(dut.i2c_nacks.value))
    dut._log.info('I2C slave: %d bytes, hash %08x, %d transactions, %d NAKed addresses' % got)
    m3su, m3h, m3w, m3n = (int(dut.m3_su_ps.value), int(dut.m3_h_ps.value), int(dut.m3_w_ps.value),
                           int(dut.m3_strobes.value))
    dut._log.info('mode 3 CE latch: %d strobes, least setup %.1f ns, hold %.1f ns, width %.1f ns'
                  % (m3n, m3su / 1000, m3h / 1000, m3w / 1000))
    assert m3n > 100 and m3su >= 2000 and m3h >= 1500 and m3w >= 3300, 'the CE latch timing is short of a 74LVC1G373'
    assert got == (len(cmds) + len(data), h, 2, 1), 'expected %d bytes %08x, 2 transactions, 1 NAK' % (len(cmds) + len(data), h)


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


# ---------------------------------------------------------------------------
# RESPIN 40 (branch tile6x4): the PLC block, the high-speed counters, the
# multiplier, UART2 for Modbus, the SP limit fault, sleep, 128 storage bits
# ---------------------------------------------------------------------------
UART2_BITCLKS = 32                       # misc40.c: UART2_DIV 0, a bit of 32 clocks


def _porta(dut, **bits):
    """set bits of the testbench's porta_in (ui_in) by number, keeping the rest -
    except bit 7, always cleared: ui_in[7] high makes the debug UART take its
    baud divider from ui_in[6:0] live (debug_brg.v), so the pins can only be
    driven in autobaud mode (the generator keeps the rate it has).  A shadow
    of the value is kept: a write lands at the end of the step, so a read
    back right after one still shows the old value"""
    v = getattr(dut, '_porta_shadow', int(dut.porta_in.value) & 0x7f)
    for k, b in bits.items():
        n = int(k[1:])
        v = (v | (1 << n)) if b else (v & ~(1 << n))
    dut._porta_shadow = v
    dut.porta_in.value = v


async def uart2_send(dut, byte, bitclks=UART2_BITCLKS):
    """bit-bang a byte into UART2's RX (ui_in[2] with uo[2] the first mux-2 pin)"""
    for bit in [0] + [(byte >> i) & 1 for i in range(8)] + [1]:
        _porta(dut, b2=bit)
        await ClockCycles(dut.clk, bitclks)


async def uart2_capture(dut, nbytes, bitclks=UART2_BITCLKS, timeout=400_000):
    """decode UART2's transmit on uo[2] (mux 2): nbytes bytes, and whether DE on
    uo[7] was high during them; returns (bytes, de_high_during, de_after)"""
    got = []
    de_seen = True
    for _ in range(timeout // 4):
        await ClockCycles(dut.clk, 4)
        if (int(dut.uo_out.value) >> 2) & 1 == 0:          # a start bit (seen within 4 clocks of a 32-clock bit)
            await ClockCycles(dut.clk, bitclks // 2 - 4)
            v = 0
            for i in range(9):
                await ClockCycles(dut.clk, bitclks)
                bit = (int(dut.uo_out.value) >> 2) & 1
                if i < 8:
                    v |= bit << i
                de_seen = de_seen and ((int(dut.uo_out.value) >> 7) & 1 == 1)
            got.append(v)
            if len(got) == nbytes:
                break
    await ClockCycles(dut.clk, 3 * bitclks)
    de_after = (int(dut.uo_out.value) >> 7) & 1
    return got, de_seen, de_after


async def hsc_stimulus(dut, delay, steps_fwd, steps_back, period, pulses_up, pulses_down):
    """after delay clocks: quadrature on ui_in[1:0] (A = bit 0, B = bit 1),
    steps_fwd forward then steps_back back, a step every period clocks; and
    pulses on ui_in[4] with ui_in[5] the direction (low up, high down)"""
    await ClockCycles(dut.clk, delay)
    seq = [(0, 0), (1, 0), (1, 1), (0, 1)]                 # A, B: forward = this order
    k = 0
    for _ in range(steps_fwd):
        k = (k + 1) % 4
        _porta(dut, b0=seq[k][0], b1=seq[k][1])
        await ClockCycles(dut.clk, period)
    for _ in range(steps_back):
        k = (k - 1) % 4
        _porta(dut, b0=seq[k][0], b1=seq[k][1])
        await ClockCycles(dut.clk, period)
    _porta(dut, b5=0)
    for _ in range(pulses_up):
        _porta(dut, b4=1)
        await ClockCycles(dut.clk, period)
        _porta(dut, b4=0)
        await ClockCycles(dut.clk, period)
    _porta(dut, b5=1)
    for _ in range(pulses_down):
        _porta(dut, b4=1)
        await ClockCycles(dut.clk, period)
        _porta(dut, b4=0)
        await ClockCycles(dut.clk, period)
    _porta(dut, b5=0)


async def misc40_stimulus(dut):
    """the pins for progs/misc40.c: two UART2 bytes once the program waits for
    them, then the first HSC burst (100 transitions forward and 25 back: 75
    in x4; HSC1: 50 pulses up and 20 down), then the second burst for the x1
    test (one count per cycle of four transitions: 25 up, 6 down, 19)"""
    await ClockCycles(dut.clk, 250_000)
    await uart2_send(dut, 0x55)
    await uart2_send(dut, 0xAA)
    await hsc_stimulus(dut, 250_000, 100, 25, 40, 50, 20)
    await hsc_stimulus(dut, 400_000, 100, 25, 40, 0, 0)


@cocotb.test(skip=plusarg('MISC40') is None)
async def test_misc40(dut):
    """+MISC40 (make MISC40=1): progs/misc40.c - RESPIN 40: the multiplier,
    sleep, UART2's FIFO / DE / idle timer, the high-speed counters and the SP
    limit fault (its interrupt, then its reset: the program restarts and finds
    FAULT).  uo[2] (tx2) and uo[7] (DE) in mux 2; the inputs from misc40_stimulus"""
    lisa = await start(dut)
    await lisa.setup(cache=False, quad=True)
    _porta(dut, b2=1)                                                # UART2's RX idles high
    await lisa.write_reg(0x1b, 0x8020 if os.environ.get('MISC40_UO7', '1') == '1' else 0x0020)   # uo[2] and uo[7] to mux 2
    cocotb.start_soon(misc40_stimulus(dut))
    cap = cocotb.start_soon(uart2_capture(dut, 8))
    text = await lisa.run(timeout=3_000_000)
    assert 'ALL PASSED' in text and 'FAIL' not in text and 'sp fault reset' in text, \
        'the RESPIN 40 test did not pass: %r' % text[-500:]
    got, de_during, de_after = await cap
    dut._log.info('UART2 sent %s, DE during %s, after %d' % (bytes(got), de_during, de_after))
    assert got == list(b'ABCDEFGH'), 'UART2 transmitted %r' % bytes(got)
    assert de_during and de_after == 0, 'DE on uo[7]: during the bytes %s, after %d' % (de_during, de_after)


async def plc_outputs(dut, wait):
    await ClockCycles(dut.clk, wait)
    return int(dut.ttlc_out.value)


@cocotb.test(skip=plusarg('PLC') is None)
async def test_plc(dut):
    """+PLC (make PLC=1): progs/plc.c sets the PLC block up from the core and
    checks it, then the ladder progs/ttlc/ttlc_plc.asm runs on the MC14500B:
    input 0 through a TON of 50000 clocks to output 0, input 1 through a TOF
    to output 1, three pulses on input 2 count to output 2 and input 3 resets
    the counter, inputs 4 / 5 pass through storage bits 64 / 127 to outputs 3 / 4"""
    lisa = await start(dut)
    await ttlcio_setup(dut, lisa, 0)
    dut.ttlc_in.value = 0
    await lisa.write_reg(0x40, 1)                                    # the ladder runs from the start: once
    text = await lisa.run(timeout=800_000)                           # the UART is the program's, the debugger is deaf
    assert 'ALL PASSED' in text and 'FAIL' not in text, 'plc.c did not pass: %r' % text[-300:]
    await ClockCycles(dut.clk, 30000)
    assert int(dut.ttlc_out.value) == 0, 'outputs %012x before any input' % int(dut.ttlc_out.value)
    # TON: output 0 follows input 0 after 100 ticks of 500 clocks
    dut.ttlc_in.value = 1 << 0
    out = await plc_outputs(dut, 15000)
    assert out & 1 == 0, 'the TON fired within 15000 clocks (%012x)' % out
    out = await plc_outputs(dut, 120000)
    assert out & 1 == 1, 'the TON did not fire by 135000 clocks (%012x)' % out
    dut.ttlc_in.value = 0
    out = await plc_outputs(dut, 15000)
    assert out & 1 == 0, 'the TON did not clear with its input (%012x)' % out
    # TOF: output 1 follows input 1 at once and holds 100 ticks after it drops
    dut.ttlc_in.value = 1 << 1
    out = await plc_outputs(dut, 15000)
    assert (out >> 1) & 1 == 1, 'the TOF did not follow its input (%012x)' % out
    dut.ttlc_in.value = 0
    out = await plc_outputs(dut, 15000)
    assert (out >> 1) & 1 == 1, 'the TOF dropped within 15000 clocks (%012x)' % out
    out = await plc_outputs(dut, 120000)
    assert (out >> 1) & 1 == 0, 'the TOF did not drop by 135000 clocks (%012x)' % out
    # the counter: three pulses on input 2, then input 3 resets it
    for n in range(3):
        dut.ttlc_in.value = 1 << 2
        await ClockCycles(dut.clk, 15000)
        dut.ttlc_in.value = 0
        out = await plc_outputs(dut, 15000)
        assert ((out >> 2) & 1) == (1 if n == 2 else 0), 'counter output after pulse %d: %012x' % (n + 1, out)
    dut.ttlc_in.value = 1 << 3
    out = await plc_outputs(dut, 15000)
    assert (out >> 2) & 1 == 0, 'the counter did not reset (%012x)' % out
    dut.ttlc_in.value = 0
    # storage bits 64 and 127
    dut.ttlc_in.value = (1 << 4) | (1 << 5)
    out = await plc_outputs(dut, 15000)
    assert (out >> 3) & 3 == 3, 'the storage loopback (64, 127): %012x' % out
    dut.ttlc_in.value = 0
    out = await plc_outputs(dut, 15000)
    assert out == 0, 'outputs %012x after all inputs cleared' % out
