#!/usr/bin/env python3
"""Run an .ihx on the Arty as arty_run.py does (the flash over Ethernet with
ETH=1, the data cache with CACHE=1), but keep the debug port: no UART
hand-over.  After the seconds (or at a breakpoint) halt the core and dump
PC / SP / RA / IX / banks, the peripheral registers, the direct data, the
stack around SP and the top of RAM.  How NuttX's non-boot was probed
(2026-10-18): the ISR frame at the interrupt entry, the trampoline's
registers step by step.
  BP=<hex window address>   a breakpoint (debug register 8); the run waits
                            for the halt up to the seconds
  BPBANK=<n>                ... in that code bank (the register compares
                            the window address only: resume on a hit
                            elsewhere)
  STEPS=<n> [VERBOSE=1]     single-step n instructions after the halt (the
                            PCs; with VERBOSE the registers each step) and
                            dump the RAM from SP (an ISR frame, say)
usage: [CACHE=1] [ETH=1] [BP=.. [BPBANK=..]] [STEPS=.. [VERBOSE=1]] arty_dump.py <file.ihx> [seconds] [baud]
Note that the peripheral reads through the debug port (INT_ENABLE, the
UART status, ...) came back 0 with the cache on; the RAM and the core's
registers are right."""
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
print("flash %s, 0x17 = %x, 0x18 = %02x" % ("quad" if quad else "single SPI", cs_cfg, dummy), flush=True)
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
# arty_dump: run without the UART hand-over, halt after the seconds, dump
def sync(pause=0.05):
    time.sleep(pause); d.ser.reset_input_buffer()
def reg(n):
    for i in range(3):
        try: return d.readReg(n)
        except Exception as e: err = e; sync()
    print("readReg(%d): %s" % (n, err)); return -1
bp = os.environ.get("BP")
if bp:
    d.writeReg(8, (int(bp, 16) & 0x7fff) | 0x8000)
    print("breakpoint at window %s" % bp, flush=True)
d.writePC(0); d.resume()
t0 = time.time()
if bp:
    # the debug port sends an 's' when the core halts at the breakpoint; the
    # breakpoint is a window address, BPBANK=<n> waits for a hit in that code bank
    want = os.environ.get("BPBANK")
    hits = 0
    while time.time() - t0 < secs:
        if d.ser.read(1) == b"s":
            hits += 1
            sync(0.05)
            b = d.readBanks()
            print("hit %d at the breakpoint after %.3f s: code bank %d SP %04X" % (hits, time.time() - t0, b["code"], reg(3)), flush=True)
            if want is None or b["code"] == int(want):
                break
            d.resume()
    else:
        print("the breakpoint was not reached in %.1f s" % secs, flush=True)
else:
    time.sleep(secs)
sync(0.2); d.halt(); sync()
pc, sp, ra, ix, ia = reg(2) & 0x7fff, reg(3), reg(4), reg(5), reg(6)
print("after %.1f s: PC %04X SP %04X RA %04X IX %04X IA %04X banks %s" % (secs, pc, sp, ra, ix, ia, d.readBanks()), flush=True)
for name, r in (("INT_ENABLE", 0x0e), ("INT_STATUS", 0x0f), ("UART1_STATUS", 0x11), ("UART_INT_EN", 0x14), ("TIM1_CTRL", 0x0c), ("TIM1_TICK", 0x0d)):
    print("  %-12s %02X" % (name, d.readByte(0x8000 | r)), flush=True)
def dump(a, n):
    b = d.readRam(a, n)
    for o in range(0, n, 16):
        print("  %04X: %s" % (a + o, " ".join("%02X" % x for x in b[o:o + 16])), flush=True)
print("direct data (g_lisa_ie 0, g_lisa_inirq 1, g_readytorun 2, g_running_tasks 6):"); dump(0x0000, 64)
print("stack around SP:"); dump(max(0, sp - 48) & 0xfff0, 96)
print("top of RAM (the idle stack):"); dump(0x7F80, 128)
steps = int(os.environ.get("STEPS", "0"))
if steps:
    tr = []
    verbose = os.environ.get("VERBOSE")
    for i in range(steps):
        d.step(); sync()
        tr.append("%04X" % (reg(2) & 0x7fff))
        if verbose:
            print("  step %2d: PC %04X A %02X IX %04X SP %04X RA %04X banks %s" % (i + 1, reg(2) & 0x7fff, reg(1) & 0xff, reg(5), reg(3), reg(4), d.readBanks()), flush=True)
    print("steps:", " ".join(tr), "banks", d.readBanks(), flush=True)
    sp2 = reg(3)
    print("after the steps: PC %04X SP %04X RA %04X IX %04X A %04X status %04X" % (reg(2) & 0x7fff, sp2, reg(4), reg(5), reg(1), reg(0)), flush=True)
    print("RAM from SP (an ISR frame: SP_LO SP_HI IE SB DB CB PC_HI PC_LO FLAGS CSAVE IRQ RA_HI RA_LO IX_HI IX_LO A):"); dump(sp2 & 0xfff0, 48)
