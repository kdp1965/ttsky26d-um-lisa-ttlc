#!/usr/bin/env python3
"""A live terminal on a program running on the Arty: the image goes into
the flash over Ethernet (ttlc_io.py), the debug port sets the design up
(the data cache on the Pmod's PSRAM unless CACHE=0), starts the program
at 0 and hands it the UART, and this terminal stays on the port - the
port must not be reopened, since opening it resets the design.  Keys go
straight through (ctrl-] quits, as pyserial's miniterm).  For lisa_monitor
press Enter for the banner and 'lisa> ', then 'help'.
usage: [CACHE=0] [QUAD=0] arty_term.py <file.ihx> [baud]     (on andromeda, the board's host)"""
import os
import sys
import time
img = sys.argv[1]
baud = int(sys.argv[2]) if len(sys.argv) > 2 else 460800
sys.argv = ["x"]
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
sys.path.insert(0, os.environ.get("LISA_PYDB", os.path.expanduser("~/projects/tiny-tapeout/ttsky26d/lisa_pydb")))
import lisa_pydb as m
from ttlc_io import TtlcIo, load_image
from serial.tools import miniterm
from serial.tools.miniterm import Miniterm


class EnterSendsCR(miniterm.Transform):
    """ENTER sends CR, as the monitor wants; what comes in is shown as it
    is (the monitor sends CR LF - miniterm's own 'cr' end-of-line setting
    would turn each CR into a second LF)"""
    def tx(self, text):
        return text.replace("\n", "\r")


miniterm.TRANSFORMATIONS["entercr"] = EnterSendsCR

TtlcIo().flash_write(0, load_image(img), log=lambda *a: print("ethernet:", *a, flush=True))
class A: flashbase = 0
d = m.LisaPyDb(); d.iwidth = 16; d.args = A()
d.openPort("/dev/ttyUSB1", baud)
print("debugger", d.getVer(), flush=True)
d.halt(); d.writePC(0); d.setFlashBase(); d.writeReg(0x17, 4); d.writeReg(0x1e, 0x0801)
cache = os.environ.get("CACHE", "1") != "0"
quad = os.environ.get("QUAD", "1") != "0"                    # both selects quad, as the demo board
d.writeReg(0x17, (0x0007 if cache else 0x0005) if quad else (0x0006 if cache else 0x0004))
d.writeReg(0x18, int(os.environ.get("DUMMY", "0x66" if quad else "0x6a"), 0))
if cache or quad:
    d.writeReg(0x1c, 0x04aa)                                    # SIO2/3 on the Pmod's SD2/SD3
if cache:
    for a, v in ((0x15, 0x0006), (0x1d, 0x0013)):
        d.writeReg(a, v)
    print("data cache on (PSRAM A on CS1), flash %s" % ("quad" if quad else "single SPI"), flush=True)
else:
    d.writeReg(0x1d, 7)
    print("data cache off (the 128-byte RAM), flash %s" % ("quad" if quad else "single SPI"), flush=True)
d.writePC(0); d.resume()
time.sleep(0.1); d.ser.read(256)
d.ser.write(b"l")                                 # the program has the UART from here
print("--- %s is running; the terminal is live, ctrl-] quits ---" % os.path.basename(img), flush=True)
d.ser.timeout = 0.05
term = Miniterm(d.ser, echo=False, eol="lf", filters=["entercr"])
term.exit_character = chr(0x1d)
term.set_rx_encoding("latin-1")
term.set_tx_encoding("latin-1")
term.start()
try:
    term.join(True)
except KeyboardInterrupt:
    pass
term.join()
term.close()
