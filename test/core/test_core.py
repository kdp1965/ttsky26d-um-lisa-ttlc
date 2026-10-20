# test_core.py - the core-level testbench (tb_core.v): the debug port driven
# directly, the program's console taken off the peripheral bus.
#   make IHX=<prog.ihx> [CACHE=1] [ILAT=1] [TIMEOUT=clocks]   run it, expect ALL PASSED
import cocotb
from cocotb.triggers import RisingEdge, First, ClockCycles

REG_STATUS, REG_ACC, REG_PC, REG_SP, REG_RA, REG_IX, REG_DATA, REG_DADDR = range(8)
REG_BRK0 = 0x08
REG_IXH, REG_SPH, REG_RAH, REG_DADDRH = 0x38, 0x39, 0x3a, 0x3c    # the upper bytes (REV3.md)


def plusarg(name, default=None):
    return cocotb.plusargs.get(name, default)


def is_dbg_program():
    return (plusarg('PROGRAM') or '').startswith('dbg')


class Timeout(Exception):
    pass


class Core:
    """the debug port of lisa_core (lisa_dbg's handshake) and the console"""

    def __init__(self, dut):
        self.dut = dut
        self.clk = dut.clk
        self.log = dut._log

    async def start(self, cache=False):
        d = self.dut
        d.rst_n.value = 0
        d.cache_disabled.value = 0 if cache else 1
        d.cache_map_sel.value = 3
        await ClockCycles(self.clk, 5)
        d.rst_n.value = 1
        await ClockCycles(self.clk, 5)
        if cache:
            d.data_cache_invalidate.value = 1
            await RisingEdge(d.data_cache_invalidate_ack)
            d.data_cache_invalidate.value = 0
            await ClockCycles(self.clk, 2)

    async def write_reg(self, a, v):
        d = self.dut
        d.dbg_a.value = a
        d.dbg_di.value = v & 0xffff
        d.dbg_we.value = 1
        await RisingEdge(self.clk)
        for _ in range(4000):          # a debugger RAM access can miss the cache
            if int(d.dbg_ready.value):
                break
            await RisingEdge(self.clk)
        else:
            raise Timeout('no dbg_ready for a write to 0x%02x' % a)
        d.dbg_we.value = 0
        await RisingEdge(self.clk)
        await RisingEdge(self.clk)

    async def read_reg(self, a):
        d = self.dut
        d.dbg_a.value = a
        d.dbg_rd.value = 1
        await RisingEdge(self.clk)
        for _ in range(4000):          # a debugger RAM access can miss the cache
            if int(d.dbg_ready.value):
                break
            await RisingEdge(self.clk)
        else:
            raise Timeout('no dbg_ready for a read of 0x%02x' % a)
        v = int(d.dbg_do.value)
        d.dbg_rd.value = 0
        await RisingEdge(self.clk)
        await RisingEdge(self.clk)
        return v

    async def halt(self):
        await self.write_reg(REG_STATUS, 1)

    async def resume(self):
        await self.write_reg(REG_STATUS, 2)

    async def step(self):
        await self.write_reg(REG_STATUS, 5)

    async def core_reset(self):
        self.dut.core_reset.value = 1
        await ClockCycles(self.clk, 3)
        self.dut.core_reset.value = 0
        await ClockCycles(self.clk, 3)

    async def read_ram(self, addr):
        await self.write_reg(REG_DADDR, addr)
        return (await self.read_reg(REG_DATA)) & 0xff

    async def write_ram(self, addr, v):
        await self.write_reg(REG_DADDR, addr)
        await self.write_reg(REG_DATA, v & 0xff)

    async def set_breakpoint(self, n, addr):
        await self.write_reg(REG_BRK0 + n, 0x8000 | addr if addr is not None else 0)

    async def wait_halted(self, timeout):
        d = self.dut
        if not int(d.dbg_halted.value):
            await First(RisingEdge(d.dbg_halted), ClockCycles(self.clk, timeout))
            if not int(d.dbg_halted.value):
                raise Timeout('not halted after %d clocks' % timeout)
        await ClockCycles(self.clk, 2)

    async def regs(self):
        r = {}
        for name, a in (('pc', REG_PC), ('sp', REG_SP), ('ra', REG_RA), ('ix', REG_IX), ('acc', REG_ACC)):
            r[name] = await self.read_reg(a)
        return r

    async def send(self, text, timeout=200_000):
        """console input, a byte at a time as the program reads them"""
        d = self.dut
        for c in text:
            d.uart_rx_d.value = ord(c)
            d.uart_rx_avail.value = 1
            await ClockCycles(self.clk, 1)
            await First(RisingEdge(d.uart_rx_rd), ClockCycles(self.clk, timeout))
            await ClockCycles(self.clk, 2)
            if int(d.uart_rx_avail.value):
                raise Timeout('the program did not read %r' % c)

    async def console_byte(self, timeout):
        d = self.dut
        t = await First(RisingEdge(d.uart_tx_wr), ClockCycles(self.clk, timeout))
        if not int(d.uart_tx_wr.value):
            return None
        return int(d.uart_tx_d.value)

    async def run(self, timeout, stop_at=('ALL PASSED', 'SOME FAILED'), send=None):
        """from PC 0 until the console shows one of stop_at, or timeout
        clocks of silence; send is typed to the program first"""
        await self.core_reset()
        await self.write_reg(REG_PC, 0)
        await self.resume()
        if send:
            cocotb.start_soon(self.send(send))
        text = ''
        line = ''
        while True:
            v = await self.console_byte(timeout)
            if v is None:
                if line:
                    self.log.info('[LISA] %s' % line)
                raise Timeout('no output for %d clocks; so far %r' % (timeout, text))
            c = chr(v) if 32 <= v < 127 or v in (9, 10, 13) else '\\x%02x' % v
            text += c
            if v == 10:
                self.log.info('[LISA] %s' % line)
                line = ''
            elif v != 13:
                line += c
            for pat in stop_at:
                if pat in text:
                    if line:
                        self.log.info('[LISA] %s' % line)
                    return text


@cocotb.test(skip=plusarg('FIRMWARE') is None or is_dbg_program())
async def test_program(dut):
    """+FIRMWARE=<hex>: run it (the data cache on with +CACHE), expect ALL PASSED"""
    core = Core(dut)
    cache = plusarg('CACHE') is not None
    await core.start(cache=cache)
    timeout = int(plusarg('TIMEOUT', 6_000_000))   # clocks of console silence (run_suite.sh's default; irq3 and alu2 compute for >500K before their first line)
    dut._log.info('running %s, data cache %s' % (plusarg('PROGRAM', '?'), 'on' if cache else 'off'))
    stop = plusarg('STOP')
    text = await core.run(timeout, stop_at=(stop,) if stop else ('ALL PASSED', 'SOME FAILED'), send=plusarg('SEND'))
    if not stop:
        assert 'ALL PASSED' in text, 'the program did not pass: %r' % text[-200:]


@cocotb.test(skip=plusarg('FIRMWARE') is not None)
async def test_debug_port(dut):
    """registers through the debug port, RAM through registers 7/6"""
    core = Core(dut)
    await core.start()
    assert (await core.read_reg(REG_STATUS)) & 1 == 1, 'not halted after reset'
    await core.write_reg(REG_PC, 0x1234)
    assert (await core.read_reg(REG_PC)) == 0x1234
    await core.write_reg(REG_IX, 0x0060)
    for a, v in ((0x10, 0x5a), (0x11, 0xa5), (0x12, 0x01)):
        await core.write_ram(a, v)
    for a, v in ((0x10, 0x5a), (0x11, 0xa5), (0x12, 0x01)):
        got = await core.read_ram(a)
        assert got == v, 'RAM[0x%02x] reads 0x%02x, wrote 0x%02x' % (a, got, v)


@cocotb.test(skip=plusarg('FIRMWARE') is not None)
async def test_debug_port_24(dut):
    """the 24-bit registers (REV3.md): the upper bytes through 0x38-0x3a, RAM beyond 32K through 0x3c"""
    core = Core(dut)
    await core.start(cache=True)
    await core.write_reg(REG_IX, 0x5678)
    await core.write_reg(REG_IXH, 0x92)          # the condition bit, bits 22:16 = 0x12
    assert (await core.read_reg(REG_IX)) == 0x5678
    assert (await core.read_reg(REG_IXH)) == 0x92
    await core.write_reg(REG_SP, 0xfff0)
    await core.write_reg(REG_SPH, 0x7f)
    assert (await core.read_reg(REG_SP)) == 0xfff0
    assert (await core.read_reg(REG_SPH)) == 0x7f
    await core.write_reg(REG_RA, 0x1234)
    await core.write_reg(REG_RAH, 0x85)
    assert (await core.read_reg(REG_RA)) == 0x1234
    assert (await core.read_reg(REG_RAH)) == 0x85
    assert (await core.read_reg(REG_IX)) == 0x5678, 'IX changed by the RA write'
    # RAM beyond 32K: 0x3c holds the address bits 22:15, 7 the rest (and the peripheral bit)
    cells = ((0x100100, 0x5a), (0x000100, 0xa5), (0x7ffffe, 0x3c), (0x7ffffe + 1, 0xc3))
    for a, v in cells:
        await core.write_reg(REG_DADDRH, a >> 15)
        await core.write_reg(REG_DADDR, a & 0x7fff)
        await core.write_reg(REG_DATA, v)
    for a, v in cells:
        await core.write_reg(REG_DADDRH, a >> 15)
        await core.write_reg(REG_DADDR, a & 0x7fff)
        got = (await core.read_reg(REG_DATA)) & 0xff
        assert got == v, 'RAM[0x%06x] reads 0x%02x, wrote 0x%02x' % (a, got, v)
    # the address steps after each access, through 0x3c
    await core.write_reg(REG_DADDRH, 0x100100 >> 15)
    await core.write_reg(REG_DADDR, 0x100100 & 0x7fff)
    assert (await core.read_reg(REG_DATA)) & 0xff == 0x5a
    assert (await core.read_reg(REG_DADDRH)) == (0x100101 >> 15), 'the upper byte after the access'
    assert (await core.read_reg(REG_DADDR)) == (0x100101 & 0x7fff), 'the lower bits after the access'
    await core.write_reg(REG_DADDRH, 0)


# ---------------------------------------------------------------- the debugger
# dbg.hex: a loop of  ldi #0xc1; sta _g1; ldi #0xc2; sta _g2; push a; ldi #0xc3;
# pop a; adx #0x15; br loop  - the immediates locate the instructions.

def load_words(path):
    mem = {}
    addr = 0
    for ln in open(path):
        for tok in ln.split():
            if tok.startswith('@'):
                addr = int(tok[1:], 16)
            else:
                mem[addr] = int(tok, 16)
                addr += 1
    words = {}
    for a in range(0, max(mem) + 1, 2):
        words[a // 2] = mem.get(a, 0xff) | (mem.get(a + 1, 0xff) << 8)
    return words


def find_word(words, w):
    hits = [pc for pc, v in words.items() if v == w]
    assert len(hits) == 1, 'word 0x%04x found %d times' % (w, len(hits))
    return hits[0]


async def dbg_start(dut):
    core = Core(dut)
    await core.start()
    words = load_words(plusarg('FIRMWARE'))
    pcs = {k: find_word(words, 0x8000 | k) for k in (0xc1, 0xc2, 0xc3)}   # ldi #k
    pcs['loop'] = pcs[0xc1]
    # the globals: sta _g1 / sta _g2 follow the ldi's
    g1 = words[pcs[0xc1] + 1] & 0x1ff
    g2 = words[pcs[0xc2] + 1] & 0x1ff
    return core, pcs, g1, g2


@cocotb.test(skip=not is_dbg_program())
async def test_bp_after_store(dut):
    """a breakpoint right after a store: the store lands and RAM[IX] is kept"""
    core, pcs, g1, g2 = await dbg_start(dut)
    await core.core_reset()
    await core.write_reg(REG_PC, 0)
    await core.resume()
    await ClockCycles(dut.clk, 3000)                      # past the banner
    await core.halt()
    await core.wait_halted(10_000)
    # a marker where IX will point while halted, and IX itself
    await core.write_ram(0x60, 0x3c)
    await core.write_ram(g1, 0x00)
    await core.write_ram(g2, 0x00)
    await core.write_reg(REG_IX, 0x60)
    await core.write_reg(REG_PC, pcs['loop'])
    await core.set_breakpoint(0, pcs[0xc2])             # right after sta _g1
    await core.resume()
    await core.wait_halted(20_000)
    r = await core.regs()
    assert r['pc'] == pcs[0xc2], 'halted at 0x%04x, not the breakpoint 0x%04x' % (r['pc'], pcs[0xc2])
    assert (await core.read_ram(g1)) == 0xc1, 'the store before the breakpoint was lost'
    assert (await core.read_ram(0x60)) == 0x3c, 'RAM[IX] was overwritten at the halt'
    # the same after the push
    await core.set_breakpoint(0, pcs[0xc3])
    sp = r['sp']
    await core.write_reg(REG_IX, 0x60)
    await core.resume()
    await core.wait_halted(20_000)
    r = await core.regs()
    assert r['pc'] == pcs[0xc3]
    assert (await core.read_ram(g2)) == 0xc2
    assert (await core.read_ram(sp - 1)) == 0xc2, 'the push before the breakpoint was lost (slot 0x%04x)' % (sp - 1)   # push a: sp--, M[sp] <= a
    assert (await core.read_ram(0x60)) == 0x3c, 'RAM[IX] was overwritten at the halt'
    await core.set_breakpoint(0, None)


@cocotb.test(skip=not is_dbg_program())
async def test_single_step(dut):
    """the step bit executes exactly one instruction, stores included"""
    core, pcs, g1, g2 = await dbg_start(dut)
    await core.write_ram(g1, 0)
    await core.write_ram(g2, 0)
    await core.write_reg(REG_PC, pcs['loop'])
    expect = [pcs['loop'] + i for i in range(1, 9)] + [pcs['loop']]
    for i, pc in enumerate(expect):
        await core.step()
        await core.wait_halted(10_000)
        r = await core.regs()
        assert r['pc'] == pc, 'step %d: PC 0x%04x, expected 0x%04x' % (i + 1, r['pc'], pc)
        if i == 1:
            assert (await core.read_ram(g1)) == 0xc1, 'sta _g1 did not land after its step'
        if i == 3:
            assert (await core.read_ram(g2)) == 0xc2, 'sta _g2 did not land after its step'
        if i == 4:
            assert (await core.read_ram(r['sp'])) == 0xc2, 'push a did not land after its step'   # SP is at the pushed byte
    assert (await core.read_reg(REG_STATUS)) & 1 == 1, 'not halted after a step'


@cocotb.test(skip=not is_dbg_program())
async def test_halt_resume(dut):
    """halt a running loop, read its state, resume, halt again"""
    core, pcs, g1, g2 = await dbg_start(dut)
    await core.core_reset()
    await core.write_reg(REG_PC, pcs['loop'])
    await core.resume()
    await ClockCycles(dut.clk, 2000)
    assert (await core.read_reg(REG_STATUS)) & 1 == 0, 'did not run'
    await core.halt()
    await core.wait_halted(10_000)
    r = await core.regs()
    assert pcs['loop'] <= r['pc'] <= pcs['loop'] + 8, 'halted at 0x%04x, outside the loop' % r['pc']
    assert (await core.read_ram(g1)) == 0xc1
    await core.resume()
    await ClockCycles(dut.clk, 1000)
    assert (await core.read_reg(REG_STATUS)) & 1 == 0
    await core.halt()
    await core.wait_halted(10_000)


# --------------------------------------------------------- an interrupt trace
@cocotb.test(skip=not (plusarg('PROGRAM') or '').startswith('irq3'))
async def test_irq_trace(dut):
    """irq3: a breakpoint on the handler's high-byte adc; at each halt the
    carry it sees, and which instruction the interrupt had landed on"""
    from cocotb.triggers import RisingEdge, First
    core = Core(dut)
    await core.start()
    words = load_words(plusarg('FIRMWARE'))
    # the handler's t += 0x0101 high byte: ldax 3(sp) (0xf203: t at 2,3(sp) above the 16-bit tick
    # count in the rev-2 frame; the only ldax n(sp) followed directly by adc #1) then adc #1 (0x9001)
    adcs = [pc + 1 for pc in words if words.get(pc) == 0xf203 and words.get(pc + 1) == 0x9001]
    dut._log.info('ldax 3(sp); adc #1 at %s' % ['0x%04x' % p for p in adcs])
    c = dut.i_lisa_core
    await core.core_reset()
    await core.write_reg(REG_PC, 0)
    await core.set_breakpoint(0, adcs[0])
    await core.resume()
    bad = []
    entries = 0
    for n in range(130):
        # the next interrupt entry, then the halt at the adc
        await First(RisingEdge(c.irq_take), RisingEdge(dut.dbg_halted))
        if int(c.irq_take.value):
            entry = (int(c.pc.value), int(c.inst.value), int(c.cond.value), int(c.cflag.value), int(c.cflag_save.value),
                     int(c.signed_inversion.value), int(c.amode.value))
            entries += 1
            await RisingEdge(dut.dbg_halted)
        r = await core.regs()
        flags = await core.read_reg(REG_ACC)
        cf = (flags >> 9) & 1
        if cf:
            bad.append((entry, r['acc'], flags))
        await core.resume()
        if entries > 120:
            break
    dut._log.info('%d entries, %d halts at the adc with C set' % (entries, len(bad)))
    for b in bad[:12]:
        e = b[0]
        dut._log.info('  interrupted pc 0x%04x inst 0x%04x cond %d C %d Csave %d inv %d amode %d -> adc sees A 0x%02x flags 0x%04x' %
                      (e + (b[1], b[2])))
    assert not bad
