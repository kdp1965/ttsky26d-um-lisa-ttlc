#!/usr/bin/env python3
"""Load an .ihx into the Arty's QSPI flash through the LISA debug port, run
it, hand it the UART and print what it sends.  One serial session: opening
the port resets the design (the Arty's DTR-to-reset jumper).
The data cache is off (0x1d = 7: the 128-byte RAM as scratchpad) unless
CACHE=1 in the environment: then it runs through the Tiny Tapeout QSPI
Pmod's PSRAM A on CS1 - psram_mod with the uio mux at 2 (0x1c = 0x4aa:
SIO2/3 on uio[4:5], CE1 on uio[6], uio[7] high), CS1 quad (0x17 = 6, the
flash on CS0 single SPI), 6 dummy clocks after its EB read (0x18 = 0x6a),
the cache on CS1 (0x15 = 6), invalidated and on with the 32K map (0x1d =
0x13).
usage: [CACHE=1] arty_run.py <file.ihx> [seconds] [baud]   (any rate; 460800 as the demo board)"""
import os, sys, time
img = sys.argv[1]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 5
baud = int(sys.argv[3]) if len(sys.argv) > 3 else 460800
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
cache = os.environ.get("CACHE") == "1"
if cache:
    for a, v in ((0x1c, 0x04aa), (0x17, 0x0006), (0x18, 0x006a), (0x15, 0x0006), (0x1d, 0x0013)):
        d.writeReg(a, v)
    for a in (0x1c, 0x17, 0x18, 0x15):
        d.ser.write(b"r%02x\n" % a); print("reg %02x = %s" % (a, d.ser.read_until(b"\r").strip().decode()))
else:
    d.writeReg(0x1d, 7)
print("data cache", "on (PSRAM A on CS1)" if cache else "off", flush=True)
d.writePC(0); d.resume()
time.sleep(0.1); d.ser.read(256)
d.ser.write(b"l")
t = time.time(); out = b""
while time.time() - t < secs:
    out += d.ser.read(256)
sys.stdout.write(out.decode(errors="replace")); print()
