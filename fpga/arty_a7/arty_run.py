#!/usr/bin/env python3
"""Load an .ihx into the Arty's QSPI flash through the LISA debug port, run
it, hand it the UART and print what it sends.  One serial session: opening
the port resets the design (the Arty's DTR-to-reset jumper).
The data cache is turned off (0x1d = 7: the 128-byte RAM as scratchpad),
since no PSRAM is wired for it.
usage: arty_run.py <file.ihx> [seconds] [baud]"""
import os, sys, time
img = sys.argv[1]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 5
baud = int(sys.argv[3]) if len(sys.argv) > 3 else 125000
sys.argv = ["x"]
sys.path.insert(0, os.environ.get("LISA_PYDB", os.path.expanduser("~/projects/tiny-tapeout/ttsky26d/lisa_pydb")))
import lisa_pydb as m
class A: flashbase = 0
d = m.LisaPyDb(); d.iwidth = 16; d.args = A()
d.openPort("/dev/ttyUSB1", baud)
print("debugger", d.getVer(), flush=True)
d.readHexFile(img)
d.loadFlash()
d.writeReg(0x10, 0)
bad = 0
for i, w in enumerate(d.opcodes[:64]):
    d.ser.write(b"r20\n"); r = d.ser.read_until(b"\r").strip().decode()
    if r != w: bad += 1
print("words %d, first 64 read back: %d mismatches" % (len(d.opcodes), bad), flush=True)
d.writeReg(0x1d, 7)
d.writePC(0); d.resume()
time.sleep(0.1); d.ser.read(256)
d.ser.write(b"l")
t = time.time(); out = b""
while time.time() - t < secs:
    out += d.ser.read(256)
sys.stdout.write(out.decode(errors="replace")); print()
