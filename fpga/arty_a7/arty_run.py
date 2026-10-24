#!/usr/bin/env python3
"""Load an .ihx into the Arty's QSPI flash through the LISA debug port, run
it, hand it the UART and print what it sends.  One serial session: opening
the port resets the design (the Arty's DTR-to-reset jumper).
The data cache is off (0x1d = 7: the 128-byte RAM as scratchpad) unless
CACHE=1 in the environment: then it runs through the Tiny Tapeout QSPI
Pmod's PSRAM A on CS1 - psram_mod with the uio mux at 2 (0x1c = 0x4aa:
SIO2/3 on uio[4:5], CE1 on uio[6], uio[7] high), the cache on CS1 (0x15 =
6), invalidated and on with the 32K map (0x1d = 0x13).
Both selects run quad (0x17: bits 1:0 quad per select, 3:2 the flash:
0x7, or 0x5 without the cache) with 6 dummy clocks after the EB address on
each (0x18 = 0x66, the Commander's and the testbench's values; the flash,
a W25Q128JV, has its QE bit set), the uio mux at 2 with psram_mod (0x1c =
0x4aa) for SIO2/3 on the Pmod's pins, since 2026-10-18 (Ken: quad for
both as the default); QUAD=0 is single SPI on the flash as before (0x17 =
6 / 4, 0x18 = 0x6a), DUMMY=0x.. another dummy setting.
ETH=1 loads the flash over Ethernet instead (ttlc_io.py's flash_write:
the bridge takes the QSPI Pmod's bus with the chip in reset, programs and
verifies the image in well under a second, gives the bus back) and uses
the debug port only to set up and run; the UART path takes minutes for a
big image.
SEND='text' is written to the program after it has the UART, a line at
a time with a pause between (escapes as in Python: SEND='\\rhelp' wakes
lisa_monitor and asks for its help; arty_term.py is the live terminal).
The capture ends at the first of STOP's markers ("ALL PASSED|SOME FAILED"
unless set; STOP= for none) or after the seconds, and the program's time
from the UART hand-over is printed.
REGS=0x1b=0x2880[,..] writes more debug registers just before the run
(0x1b = 0x2880: the SPI master's CS0 / SCLK / MOSI on uo[3] / [5] / [6]).
SPI=0x.... sets register 0x1e after the load (bits 3:0 SCLK = clk / (2 (n + 1)),
10:4 the gap between transactions in clocks, 12:11 the SPI mode per select,
14:13 the late read capture per select): 0x0010 unless given - clk/2, a
1-clock gap, mode 0 (since RESPIN 34, 2026-10-24: clk/2 failed with the cache
on because a write burst changed each later word's first nibble on SCLK's
rising edge; a bitstream from before needs SPI=0x0811 - clk/4, mode 1 on
the flash; 0x6010 adds the late capture, which the Arty does not need).  The load
leaves 0x08d3 - clk/8, a 13-clock gap - the emulated RAM's settings, which the
TT07 board still needs (lisa_pydb keeps them); the testbench runs 0x0010.
usage: [CACHE=1] [ETH=1] [QUAD=0] [DUMMY=0x66] [SPI=0x..] [REGS=a=v,..] [SEND=..] [STOP=..] arty_run.py <file.ihx> [seconds] [baud]   (any rate; 460800 as the demo board)"""
import os, sys, time
img = sys.argv[1]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 5
baud = int(sys.argv[3]) if len(sys.argv) > 3 else 460800
sys.argv = ["x"]
sys.path.insert(0, os.environ.get("LISA_PYDB", os.path.expanduser("~/projects/tiny-tapeout/ttsky26d/lisa_pydb")))
import lisa_pydb as m
eth = os.environ.get("ETH") == "1"
if eth:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from ttlc_io import TtlcIo, load_image
    TtlcIo().flash_write(0, load_image(img), log=lambda *a: print("ethernet:", *a, flush=True))
class A: flashbase = 0
d = m.LisaPyDb(); d.iwidth = 16; d.args = A()
d.openPort("/dev/ttyUSB1", baud)
print("debugger", d.getVer(), flush=True)
d.readHexFile(img)
if eth:
    # what loadFlash sets besides erasing and writing: the core halted at 0,
    # the debug and fetch bases, the uo / uio muxes, the flash single SPI
    d.halt(); d.writePC(0); d.setFlashBase(); d.writeReg(0x17, 4); d.writeReg(0x1e, 0x08d3)
else:
    d.loadFlash()
cache = os.environ.get("CACHE") == "1"
quad = os.environ.get("QUAD", "1") != "0"
cs_cfg = (0x0007 if cache else 0x0005) if quad else (0x0006 if cache else 0x0004)
dummy = int(os.environ.get("DUMMY", "0x66" if quad else "0x6a"), 0)
if cache or quad:                                # psram_mod + the uio mux at 2: SIO2/3 on uio[4:5], the Pmod's SD2/SD3
    d.writeReg(0x1c, 0x04aa)
d.writeReg(0x17, cs_cfg); d.writeReg(0x18, dummy)
spi = os.environ.get("SPI", "0x0010")            # register 0x1e: bits 3:0 SCLK = clk / (2 (n + 1)), 10:4 the CE gap in clocks,
d.writeReg(0x1e, int(spi, 0))                    # 12:11 the mode per select; the load leaves 0x08d3 (clk/8, 13, mode 1 on the flash)
print("flash %s, 0x17 = %x, 0x18 = %02x, 0x1e = %04x" % ("quad" if quad else "single SPI", cs_cfg, dummy, int(spi, 0)), flush=True)
d.writeReg(0x10, 0)
bad = 0
for i, w in enumerate(d.opcodes[:64]):          # read back through the selected mode: a check of it
    d.ser.write(b"r20\n"); r = d.ser.read_until(b"\r").strip().decode()
    if r != w: bad += 1
print("words %d, first 64 read back: %d mismatches" % (len(d.opcodes), bad), flush=True)
if cache:
    for a, v in ((0x15, 0x0006), (0x1d, 0x0013)):
        d.writeReg(a, v)
else:
    d.writeReg(0x1d, 7)
print("data cache", "on (PSRAM A on CS1, quad)" if cache else "off", flush=True)
for rv in os.environ.get("REGS", "").split(","):  # REGS=0x1b=0x2880,...: more debug registers (e.g. the uo_out mux)
    if rv:
        a, v = rv.split("=")
        d.writeReg(int(a, 0), int(v, 0))
        print("debug register %02x = %04x" % (int(a, 0), int(v, 0)), flush=True)
d.writePC(0); d.resume()
time.sleep(0.1); d.ser.read(256)
d.ser.write(b"l")
if os.environ.get("SEND"):
    # a line at a time with a pause: lisa_monitor drops what arrived while it
    # printed the banner, so a command queued behind the Enter would be lost
    for line in os.environ["SEND"].encode().decode("unicode_escape").split("\r"):
        time.sleep(0.6)
        for c in line.encode() + b"\r":          # a character at a time: the chip's 8-byte
            d.ser.write(bytes([c])); time.sleep(0.005)   # RX FIFO is slower to drain than 460800 baud
    time.sleep(0.3)
t = time.time(); out = b""
stop = [m.encode() for m in os.environ.get("STOP", "ALL PASSED|SOME FAILED").split("|") if m]
while time.time() - t < secs:
    out += d.ser.read(256)
    if any(m in out for m in stop):
        break
ran = time.time() - t
sys.stdout.write(out.decode(errors="replace")); print()
print("program: %.2f s from the UART hand-over%s" % (ran, " to " + next(m.decode() for m in stop if m in out) if any(m in out for m in stop) else " (window)"), flush=True)
