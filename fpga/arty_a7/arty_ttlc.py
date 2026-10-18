#!/usr/bin/env python3
"""Load a TTLC program into the Arty's QSPI flash at byte 0x10000 through
the LISA debug port, start the TTLC, then run the loopback check over
Ethernet: the program (test/progs/ttlc/ttlc_loopback.hex, the chip
testbench's) copies the 48 inputs to the 48 outputs through the FPGA's
chains, which ttlc_io.py reaches at 192.168.1.200.  One serial session:
opening the port resets the design.  SW3 must be down (the inside chains).
ETH=1 writes the image over Ethernet (ttlc_io.py's flash_write) and uses
the debug port only to set up and start the TTLC.
usage: [ETH=1] [QUAD=0] arty_ttlc.py <program.hex> [baud]   (readmemh bytes, as the testbench's flash image; any baud rate, 460800 as the demo board)"""
import os
import sys
import time
img = sys.argv[1]
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 460800
sys.argv = ['x']
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
sys.path.insert(0, os.environ.get('LISA_PYDB', os.path.expanduser('~/projects/tiny-tapeout/ttsky26d/lisa_pydb')))
import lisa_pydb as m
from ttlc_io import TtlcIo

# the program: '@addr' then hex bytes, low byte of each word first
data, addr = {}, 0
for line in open(img):
    for tok in line.split():
        if tok.startswith('@'):
            addr = int(tok[1:], 16)
        else:
            data[addr] = int(tok, 16)
            addr += 1
words = (max(data) + 2) // 2
opcodes = ['%02x%02x' % (data.get(2 * w + 1, 0), data.get(2 * w, 0)) for w in range(words)]


eth = os.environ.get('ETH') == '1'
if eth:
    from ttlc_io import load_image
    TtlcIo().flash_write(0x10000, load_image(img), log=lambda *a: print('ethernet:', *a, flush=True))
class A: flashbase = 0x10000
d = m.LisaPyDb(); d.iwidth = 16; d.args = A()
d.openPort('/dev/ttyUSB1', baud)
print('debugger', d.getVer(), flush=True)
d.opcodes = opcodes
if eth:
    d.halt(); d.writePC(0); d.setFlashBase(); d.writeReg(0x17, 4); d.writeReg(0x1e, 0x08d3)
else:
    d.loadFlash()                               # halts LISA, erases the 64K block at 0x10000, writes
d.writeReg(0x11, 1); d.writeReg(0x10, 0)        # read back from 0x10000
bad = 0
for w in opcodes:
    d.ser.write(b'r20\n'); r = d.ser.read_until(b'\r').strip().decode()
    if r != w: bad += 1
print('%d words at 0x10000, read back: %d mismatches' % (len(opcodes), bad), flush=True)
# the TTLC: its base 0x10000, CS0, uo_out to its chains (0x1b), the scan's
# shift clock from 0x1c bits 9:8 (0: clk/2); the flash stays single SPI
quad = os.environ.get('QUAD', '1') != '0'                    # the flash quad, as the testbench runs the TTLC
d.writeReg(0x17, 0x0005 if quad else 0x0004); d.writeReg(0x18, int(os.environ.get('DUMMY', '0x66' if quad else '0x6a'), 0))
for a, v in ((0x1f, 0x0100), (0x15, 0x0004), (0x1b, 0x3cff), (0x1c, 0x04aa if quad else 0x0000)):
    d.writeReg(a, v)
d.writeReg(0x40, 1)                             # run
time.sleep(0.05)
st = d.readReg(0x40); pc = d.readReg(0x41)
print('TTLC status 0x%04x pc 0x%04x (group %d slot %d)' % (st, pc, pc >> 2, pc & 3), flush=True)
io = TtlcIo()
print('bridge:', io.read(), flush=True)
fails = 0
for pat in (0x123456789abc, 1, 0x800000000000, 0xaaaaaaaaaaaa, 0xffffffffffff, 0, 0x5a5a5a5a5a5a):
    io.inputs(pat)
    time.sleep(0.01)
    s = io.read()
    ok = s.outputs == pat
    fails += not ok
    print('inputs %012x -> outputs %012x %s' % (pat, s.outputs, 'ok' if ok else 'WRONG'), flush=True)
pc2 = d.readReg(0x41)
print('TTLC pc 0x%04x, %s' % (pc2, 'ALL PASSED' if not fails else 'SOME FAILED'))
