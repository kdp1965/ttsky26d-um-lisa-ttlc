"""lisa.py - drive tt_um_pettit_lisa through the testbench's UART: the debugger
protocol (rXX / wXXYYYY / v / t / l), the configuration registers the LISA
Commander writes, and running a program from the flash model.

Everything waits on signal edges, not on clock polls, so the simulation runs
at the simulator's own speed between events.
"""
import os
import cocotb
from cocotb.triggers import RisingEdge, First, ClockCycles

# a character on the testbench UART: 10 bits x 32 x (baud_div + 1) clocks
# when the chip's divider pins set the rate (reset(), the default); with the
# autobaud (reset(autobaud=True, bitclks=n)) the testbench UART's bit is any
# number of clocks (tb.v's bitclks) and the chip measures it
BAUD_DIV = 8          # bit 3 must be set: ui_in[3] is the RX pin (idle 1) in this testbench
BIT_CYCLES = 32 * (BAUD_DIV + 1)         # debug_brg: a bit is 32 x (div + 1) clocks
CHAR_CYCLES = 10 * BIT_CYCLES

# debug registers (debug_regs.v)
REG_STATUS, REG_ACC, REG_PC, REG_SP, REG_RA, REG_IX, REG_DATA, REG_DADDR = range(8)
REG_BRK0 = 0x08
REG_DBG_ADDR_L, REG_DBG_ADDR_H, REG_LISA1_BASE, REG_LISA2_BASE = 0x10, 0x11, 0x12, 0x13
REG_LISA1_CE, REG_LISA2_CE, REG_DBG_CE, REG_CS_CFG, REG_DUMMY = 0x14, 0x15, 0x16, 0x17, 0x18
REG_OUT_MUX, REG_IO_MUX, REG_CACHE, REG_SPI, REG_TTLC_BASE = 0x1b, 0x1c, 0x1d, 0x1e, 0x1f


class Timeout(Exception):
    pass


class Lisa:
    def __init__(self, dut):
        self.dut = dut
        self.clk = dut.clk
        self.log = dut._log

    async def cycles(self, n):
        await ClockCycles(self.clk, n)

    # ------------------------------------------------------------- the UART
    async def tx(self, byte):
        d = self.dut
        if not int(d.tx_buf_empty.value):
            await RisingEdge(d.tx_buf_empty)
        await ClockCycles(self.clk, 1)
        d.tx_d.value = byte
        d.tx_wr.value = 1
        await ClockCycles(self.clk, 2)
        d.tx_wr.value = 0
        await ClockCycles(self.clk, 2)

    async def tx_str(self, s):
        for c in s:
            await self.tx(ord(c))

    async def rx(self, timeout=20 * CHAR_CYCLES):
        """one byte from the DUT, or None after timeout clocks"""
        d = self.dut
        if not int(d.rx_avail.value):
            await First(RisingEdge(d.rx_avail), ClockCycles(self.clk, timeout))
            if not int(d.rx_avail.value):
                return None
        v = int(d.rx_d.value)
        d.rx_rd.value = 1
        await ClockCycles(self.clk, 1)
        d.rx_rd.value = 0
        await ClockCycles(self.clk, 2)
        return v

    async def rx_line(self, timeout=20 * CHAR_CYCLES):
        """bytes up to and including a CR (the debugger ends replies with LF CR)"""
        out = bytearray()
        while True:
            v = await self.rx(timeout)
            if v is None:
                raise Timeout('no reply (got %r)' % bytes(out))
            out.append(v)
            if v == 0x0d:
                return bytes(out)

    async def drain(self, quiet=3 * CHAR_CYCLES):
        out = bytearray()
        while True:
            v = await self.rx(quiet)
            if v is None:
                return bytes(out)
            out.append(v)

    # --------------------------------------------------------- the debugger
    async def reset(self, autobaud=False, bitclks=BIT_CYCLES):
        d = self.dut
        d.ena.value = 1
        d.bitclks.value = bitclks                   # the testbench UART's bit
        d.porta_in.value = 0 if autobaud else 0x80 | BAUD_DIV   # ui_in[7]: fixed baud divider
        d.uart_port_sel.value = 0                   # ui_in[3] / uo_out[4]
        d.tx_wr.value = 0
        d.rx_rd.value = 0
        d.tx_d.value = 0
        d.rst_n.value = 0
        await ClockCycles(self.clk, 10)
        d.rst_n.value = 1
        await ClockCycles(self.clk, 40)
        # the first edge on an RX input selects the debug port; with the
        # autobaud the character also sets the baud rate, and the port is
        # connected once the line has idled 16383 clocks after it (the
        # host tools sleep 150 to 200 ms there)
        await self.tx(0x0a)
        await self.drain()
        if autobaud:
            await ClockCycles(self.clk, 17000)

    # v, t and l are single-character commands: a newline after them is
    # parsed as another command and answered with LF CR
    async def version(self):
        await self.tx_str('v')
        line = await self.rx_line()
        return line.decode(errors='replace').strip()

    async def write_reg(self, a, v):
        await self.tx_str('w%02x%04x\n' % (a, v & 0xffff))

    async def read_reg(self, a):
        await self.tx_str('r%02x\n' % a)
        line = await self.rx_line()
        s = line.decode(errors='replace')
        for i in range(len(s) - 3):
            tok = s[i:i + 4]
            if all(c in '0123456789abcdef' for c in tok):
                return int(tok, 16)
        raise ValueError('bad reply %r to r%02x' % (line, a))

    async def check_reg(self, a, v):
        got = await self.read_reg(a)
        assert got == v, 'register 0x%02x reads 0x%04x, wrote 0x%04x' % (a, got, v)

    async def core_reset(self):
        await self.tx_str('t')
        await ClockCycles(self.clk, 20)

    async def grant_uart(self):
        await self.tx_str('l')
        await ClockCycles(self.clk, 20)

    async def halt(self):
        await self.write_reg(REG_STATUS, 1)

    async def resume(self):
        await self.write_reg(REG_STATUS, 2)

    async def read_ram(self, addr):
        """RAM through the debugger (register 6 at the address in 7); the
        core must be halted"""
        await self.write_reg(REG_DADDR, addr)
        return await self.read_reg(REG_DATA) & 0xff

    async def write_ram(self, addr, v):
        await self.write_reg(REG_DADDR, addr)
        await self.write_reg(REG_DATA, v & 0xff)

    # ------------------------------------------------------ the configuration
    async def setup(self, cache=False, quad=True, verify=True):
        """the Commander's setup: CS0 the program flash, CS1 the data RAM,
        both QSPI with 24-bit addresses (the testbench models), the fetch
        and data bases 0; the data cache off (the 128-byte RAM is the data
        space) or on (32K through the RAM model on CS1)"""
        regs = [
            (REG_IO_MUX,     0x00a3 if quad else 0x0003),   # uio6/7 DQ2/DQ3, uio4 CE1
            (REG_OUT_MUX,    0x0000),
            (REG_CS_CFG,     0x0007 if quad else 0x0004),   # {addr16, is_flash, quad} per CS
            (REG_DUMMY,      0x0066),                       # 6 dummy clocks after an EB address
            (REG_SPI,        int(os.environ.get('SPI_REG', '0x0010'), 0)),  # mode 0, CE delay 1, SCLK clk/2;
                                                            # SPI_REG=0x6010 adds the late read capture (RESPIN 34)
            (REG_DBG_ADDR_L, 0x0000),
            (REG_DBG_ADDR_H, 0x0000),
            (REG_LISA1_BASE, 0x0000),
            (REG_LISA2_BASE, 0x0000),
            (REG_LISA1_CE,   0x0001),
            (REG_LISA2_CE,   0x0006),                       # TTLC CS0, data cache CS1
            (REG_DBG_CE,     0x0001),
            (REG_CACHE,      0x0013 if cache else 0x0007),  # map 3 (32K); invalidate | enable, or disabled
        ]
        for a, v in regs:
            await self.write_reg(a, v)
        if verify:
            for a, v in regs:
                if a in (REG_CACHE,):
                    continue
                await self.check_reg(a, v)
        self.cache = cache

    # ------------------------------------------------------------ programs
    async def run(self, timeout, stop_at=('ALL PASSED', 'SOME FAILED'), send=None, send_delay=0,
            send_prompt=None):
        """resume the core at PC 0 with the UART granted to the program;
        collect its output until one of stop_at appears, or timeout clocks
        of silence.  Returns the text.  send is typed to the program after
        send_delay clocks (a shell wants its prompt up first).  With send_prompt
        (a shell's prompt) send is typed a line at a time (the lines end in
        '\\r'), each once the prompt has shown since the one before: the chip
        holds 8 bytes and the driver 63, a slow program loses the rest."""
        await self.core_reset()
        await self.write_reg(REG_PC, 0)
        await self.resume()
        await self.grant_uart()
        if send and not send_delay and not send_prompt:
            await self.tx_str(send)
            send = None
        # typed from this loop: at send_delay clocks, and with send_prompt a
        # line at a time, each after the prompt has shown (the first one too)
        chunks = ([l + '\r' for l in send.split('\r') if l] if send_prompt else [send]) if send else []
        ready = not send_prompt                      # the next chunk may go
        mark = 0                                     # the prompt is looked for in text[mark:]
        text = ''
        line = ''
        while True:
            wait = timeout
            if chunks:
                left = send_delay - int(self.dut.tr_cycle.value)
                if left <= 0 and ready:
                    self.log.info('[LISA] typing %r' % chunks[0])
                    for c in chunks.pop(0):
                        await self.tx_str(c)
                        await ClockCycles(self.clk, 4 * CHAR_CYCLES)   # the program's turn to read it
                    if send_prompt:
                        ready = False
                        mark = len(text)
                    continue
                if left > 0:
                    wait = min(timeout, left)
            v = await self.rx(wait)
            if v is None and chunks and wait < timeout:
                continue                             # time to type, not silence
            if v is None:
                self.log.info('[LISA] %s' % line) if line else None
                raise Timeout('no output for %d clocks; so far: %r' % (timeout, text))
            c = chr(v) if 32 <= v < 127 or v in (9, 10, 13) else '\\x%02x' % v
            text += c
            if not ready and send_prompt in text[mark:]:
                ready = True
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
