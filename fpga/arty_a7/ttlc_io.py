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

Command line: ttlc_io.py [host] read | in <hex48> | watch [quiet seconds] | ping
Protocol: a command byte, I with six little-endian bytes; every datagram
is answered with the 20-byte status (ttlc_eth_app.v); E is the same for a
change of the outputs after S."""
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

    def request(self, payload):
        """send a command, return its status reply; a reply lost on the
        wire (or dropped by the bridge under a burst) is retried"""
        for _ in range(self.retries):
            self.sock.sendto(payload, self.addr)
            try:
                while True:
                    data, src = self.sock.recvfrom(64)
                    if len(data) >= 20 and data[0] == ord('S'):
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
