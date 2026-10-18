#!/usr/bin/env python3
"""The TTLC's I/O on the Arty over Ethernet (eth_ttlc.v): the 48 inputs
the FPGA's 74HC165 chains load and the 48 outputs its 74HC595 chains hold,
as UDP datagrams to port 14500 at the board's address (192.168.1.200).

    from ttlc_io import TtlcIo
    io = TtlcIo()
    io.inputs(0x123456789abc)       # set the inputs; returns the status
    st = io.read()                  # st.outputs, st.inputs, st.us, ...
    for ev in io.events():          # subscribe; an Event per output change
        print(ev)

The bridge can also take the QSPI Pmod's flash bus (the chip held in
reset meanwhile) and run SPI transactions on it, so a program image goes
into the flash in milliseconds instead of through the debug UART:

    io.flash_write(0, load_image('hello_rev2.ihx'))     # erase, program, verify
    io.flash_read(0x10000, 64)

Command line: ttlc_io.py [host] read | in <hex48> | watch [quiet seconds] | ping
               | flash id | flash read <hexaddr> <n> | flash erase <hexaddr>
               | flash write <file> [hexbase] | flash release
Protocol: a command byte, I with six little-endian bytes; every datagram
is answered with the 20-byte status (ttlc_eth_app.v); E is the same for a
change of the outputs after S.  X takes the flash bus, Y gives it back,
T <bytes> is one SPI transaction answered with T and the bytes read."""
import socket
import struct
import sys
import time
from collections import namedtuple

HOST = '192.168.1.200'
PORT = 14500
Status = namedtuple('Status', 'type flags us outputs inputs events')


class TtlcIo:
    def __init__(self, host=HOST, port=PORT, timeout=0.2, retries=5):
        self.addr = (host, port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(timeout)
        self.retries = retries

    @staticmethod
    def parse(data):
        t, flags, us, out, inp, events = struct.unpack('<BBI6s6sH', data[:20])
        return Status(chr(t), flags, us, int.from_bytes(out, 'little'), int.from_bytes(inp, 'little'), events)

    def request(self, payload, kind=b'S'):
        """send a command, return its reply: the Status for an S reply, the
        bytes read for a T reply.  A reply lost on the wire (or dropped by
        the bridge under a burst) is retried; a T answered with a status
        means the bus is not held"""
        for _ in range(self.retries):
            self.sock.sendto(payload, self.addr)
            try:
                while True:
                    data, src = self.sock.recvfrom(2048)
                    if not data:
                        continue
                    if data[0] == ord('T') and kind == b'T':
                        return data[1:]
                    if data[0] == ord('S') and len(data) >= 20:
                        if kind == b'T':
                            raise RuntimeError('the bridge does not hold the flash bus (flash_take first)')
                        return self.parse(data)
            except socket.timeout:
                continue
        raise TimeoutError('no reply from %s:%d' % self.addr)

    def read(self):
        return self.request(b'R')

    def inputs(self, value):
        return self.request(b'I' + (value & 0xffffffffffff).to_bytes(6, 'little'))

    def subscribe(self):
        return self.request(b'S')

    def unsubscribe(self):
        return self.request(b'U')

    # ------------------------------------------------------------- the flash
    def flash_take(self):
        st = self.request(b'X')
        if not st.flags & 4:
            raise RuntimeError('the bridge did not take the flash bus')
        return st

    def flash_release(self):
        return self.request(b'Y')

    def spi(self, data):
        """one transaction while the bus is held: CS low, the bytes out, the
        bytes read on MISO back (up to 1024)"""
        return self.request(b'T' + bytes(data), kind=b'T')

    def flash_id(self):
        return self.spi(b'\x9f\0\0\0')[1:4]

    def flash_status(self):
        return self.spi(b'\x05\0')[1]

    def flash_wait(self, timeout=5.0):
        t = time.time()
        while self.flash_status() & 1:
            if time.time() - t > timeout:
                raise TimeoutError('the flash stayed busy')

    def flash_erase_block(self, addr):
        """the 64 KB block holding addr"""
        self.spi(b'\x06')
        self.spi(bytes([0xd8, (addr >> 16) & 0xff, (addr >> 8) & 0xff, addr & 0xff]))
        self.flash_wait()

    def flash_program_page(self, addr, data):
        """up to 256 bytes within one page"""
        assert len(data) <= 256 - (addr & 0xff)
        self.spi(b'\x06')
        self.spi(bytes([0x02, (addr >> 16) & 0xff, (addr >> 8) & 0xff, addr & 0xff]) + bytes(data))
        self.flash_wait()

    def flash_read(self, addr, n):
        out = b''
        while len(out) < n:
            k = min(1020, n - len(out))
            a = addr + len(out)
            out += self.spi(bytes([0x03, (a >> 16) & 0xff, (a >> 8) & 0xff, a & 0xff]) + b'\0' * k)[4:]
        return out

    def flash_write(self, addr, data, erase=True, verify=True, log=None):
        """take the bus, erase the 64 KB blocks the image covers, program
        it page by page, read it back, give the bus back.  The chip
        restarts when the bus is released (open the debug port after)."""
        log = log or (lambda *a: None)
        t0 = time.time()
        self.flash_take()
        try:
            self.spi(b'\xff\xff')                     # out of a continuous-read mode, if the chip left it there
            ident = self.flash_id()
            log('flash id %s' % ident.hex())
            if ident in (b'\x00\x00\x00', b'\xff\xff\xff'):
                raise RuntimeError('no flash answers (id %s)' % ident.hex())
            # the runs of the image: a gap of 512 or more zero bytes is the
            # loader's fill between code banks (bank n at byte n * 0x8000),
            # not program - it is skipped and left erased
            runs, i, n = [], 0, len(data)
            while i < n:
                j = i
                while j < n and not (data[j] == 0 and data[j:j + 512] == bytes(min(512, n - j))):
                    j += 1
                if j > i:
                    runs.append((i, j))
                while j < n and data[j] == 0:
                    j += 1
                if j - (runs[-1][1] if runs else 0) < 512 and runs and j < n:
                    runs[-1] = (runs[-1][0], j)          # a short zero run is program after all
                i = j
            if erase:
                blocks = sorted({b for r0, r1 in runs for b in range((addr + r0) >> 16, ((addr + r1 - 1) >> 16) + 1)})
                for b in blocks:
                    self.flash_erase_block(b << 16)
                log('erased %d block(s) of 64 KB in %.2f s' % (len(blocks), time.time() - t0))
            written = 0
            for r0, r1 in runs:
                a = addr + r0
                while a < addr + r1:
                    k = min(256 - (a & 0xff), addr + r1 - a)
                    self.flash_program_page(a, data[a - addr:a - addr + k])
                    a += k
                written += r1 - r0
            log('programmed %d bytes at 0x%x in %.2f s%s' % (written, addr, time.time() - t0,
                '' if written == len(data) else ' (%d run(s), the gaps left erased)' % len(runs)))
            if verify:
                for r0, r1 in runs:
                    back = self.flash_read(addr + r0, r1 - r0)
                    bad = [i for i in range(r1 - r0) if back[i] != data[r0 + i]]
                    if bad:
                        raise RuntimeError('verify failed at %d bytes, the first at 0x%x: %02x read, %02x written' % (len(bad), addr + r0 + bad[0], back[bad[0]], data[r0 + bad[0]]))
                log('verified in %.2f s' % (time.time() - t0))
        finally:
            self.flash_release()

    def events(self, timeout=None):
        """subscribe and yield each E datagram (an output change) as it
        comes, until timeout seconds (None: forever) pass without one"""
        self.subscribe()
        self.sock.settimeout(timeout)
        try:
            while True:
                try:
                    data, src = self.sock.recvfrom(64)
                except socket.timeout:
                    return
                if len(data) >= 20 and data[0] == ord('E'):
                    yield self.parse(data)
        finally:
            self.sock.settimeout(0.2)
            try:
                self.unsubscribe()
            except TimeoutError:
                pass


def load_image(path):
    """a program image as flash bytes: Intel HEX (sdcc -mlisa's .ihx; byte
    addresses, gaps zero as the debug loader writes them), readmemh bytes
    ('@addr' then hex bytes, the testbench's flash images), or raw binary"""
    data = {}
    text = open(path, 'rb').read()
    if text.startswith(b':'):
        upper = 0                       # type 02 / 04: the address above 64 KB (code banks)
        for line in text.decode().split():
            n, a, t = int(line[1:3], 16), int(line[3:7], 16), int(line[7:9], 16)
            if t == 1:
                break
            if t in (2, 4):
                upper = int(line[9:13], 16) << (16 if t == 4 else 4)
            if t == 0:
                for i in range(n):
                    data[upper + a + i] = int(line[9 + 2 * i:11 + 2 * i], 16)
    elif text.lstrip().startswith(b'@') or all(c in b'0123456789abcdefABCDEF@ \t\r\n' for c in text[:64]):
        a = 0
        for tok in text.decode().split():
            if tok.startswith('@'):
                a = int(tok[1:], 16)
            else:
                data[a] = int(tok, 16); a += 1
    else:
        return bytes(text)
    if not data:
        return b''
    return bytes(data.get(i, 0) for i in range(max(data) + 1))


def main(argv):
    args = list(argv)
    host = HOST
    if args and args[0][0].isdigit():
        host = args.pop(0)
    io = TtlcIo(host)
    cmd = args[0] if args else 'read'
    if cmd == 'read':
        st = io.read()
    elif cmd == 'in':
        st = io.inputs(int(args[1], 16))
    elif cmd == 'ping':
        t = time.time()
        for _ in range(100):
            io.read()
        print('100 round trips: %.2f ms each' % ((time.time() - t) * 10))
        return
    elif cmd == 'flash':
        sub = args[1] if len(args) > 1 else 'id'
        if sub == 'id':
            io.flash_take()
            try:
                io.spi(b'\xff\xff'); print('flash id', io.flash_id().hex(), 'status %02x' % io.flash_status())
            finally:
                io.flash_release()
        elif sub == 'read':
            a, n = int(args[2], 16), int(args[3])
            io.flash_take()
            try:
                io.spi(b'\xff\xff'); d = io.flash_read(a, n)
            finally:
                io.flash_release()
            for i in range(0, len(d), 16):
                print('%06x: %s' % (a + i, ' '.join('%02x' % b for b in d[i:i + 16])))
        elif sub == 'erase':
            io.flash_take()
            try:
                io.spi(b'\xff\xff'); io.flash_erase_block(int(args[2], 16)); print('erased the 64 KB block at 0x%x' % (int(args[2], 16) & ~0xffff))
            finally:
                io.flash_release()
        elif sub == 'write':
            base = int(args[3], 16) if len(args) > 3 else 0
            io.flash_write(base, load_image(args[2]), log=print)
        elif sub == 'release':
            print(io.flash_release())
        else:
            print(__doc__)
        return
    elif cmd == 'watch':
        quiet = float(args[1]) if len(args) > 1 else None
        print('outputs as they change (%s):' % ('ctrl-C ends' if quiet is None else 'until %g s pass without one' % quiet), flush=True)
        for ev in io.events(quiet):
            print('%10.3f s  outputs %012x  inputs %012x  event %d' % (ev.us / 1e6, ev.outputs, ev.inputs, ev.events), flush=True)
        return
    else:
        print(__doc__)
        return
    print('outputs %012x  inputs %012x  %.3f s  events %d  flags %02x (%s%s)' % (
        st.outputs, st.inputs, st.us / 1e6, st.events, st.flags,
        'subscribed' if st.flags & 1 else 'not subscribed', ', Pmod chains' if st.flags & 2 else ', inside chains'))


if __name__ == '__main__':
    main(sys.argv[1:])
