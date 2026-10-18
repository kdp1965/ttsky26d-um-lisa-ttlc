# Test programs for the revision-2 RTL (sdcc -mlisa --rev2 from lisa-tools:
# the second chip's stack convention - SP at the top byte - and its adder;
# the .hex images are committed so the testbenches run without the compiler).
#   make            build *.ihx and the *.hex the flash model / tb_core load
SDCC      ?= ../../../lisa-tools/sdcc-lisa/build/bin/sdcc
SDCC_TEST ?= ../../../lisa-tools/sdcc_test
CFLAGS    ?= -mlisa --rev2 --debug -I$(SDCC_TEST)

PROGS = hello alu2 reti div16 cache14 dbg swap bank

all: $(PROGS:%=%.hex) ttlc_test.hex ttlc_jump_test.hex bank_test.hex

# the TTLC programs (ttlc/*.asm, assembled by ttlc/mc14500_as.py into the
# slot format of ttlc_fetch.v) at byte 0x10000 of the flash, behind hello:
# the TTLC base register 0x1f = 0x100.  ttlc_loopback copies the 48 inputs
# to the 48 outputs every scan; ttlc_jump does it through jmp / rtn / skz
ttlc/%.hex: ttlc/%.asm ttlc/mc14500_as.py
	cd ttlc && python3 mc14500_as.py --quiet $(notdir $<)

ttlc_test.hex: hello.hex ttlc/ttlc_loopback.hex ../hexcat.py
	python3 ../hexcat.py $@ 0 hello.hex 10000 ttlc/ttlc_loopback.hex

ttlc_jump_test.hex: hello.hex ttlc/ttlc_jump.hex ../hexcat.py
	python3 ../hexcat.py $@ 0 hello.hex 10000 ttlc/ttlc_jump.hex

%.ihx: %.c $(SDCC_TEST)/harness.h
	$(SDCC) $(CFLAGS) -o $@ $<

# the cache test uses the 32K data space: stack at the top, data low (TT07's
# --tt07-cache laid that out with its workarounds; --rev2 excludes it)
cache14.ihx: CFLAGS += --stack-loc 0x7fff
bank.ihx: CFLAGS += --stack-loc 0x7fff

# the bank test (RESPIN 22): bank.c at 0 and `ldi #bank; ret` at word 0x4000
# of code banks 1, 2, 3 (flash bytes 0x8000, 0x10000, 0x18000: bank_stubs.hex)
bank_test.hex: bank.hex bank_stubs.hex ../hexcat.py
	python3 ../hexcat.py $@ 0 bank.hex 0 bank_stubs.hex

%.hex: %.ihx ../ihx2hex.py
	python3 ../ihx2hex.py $< $@

clean:
	rm -f *.ihx *.hex *.asm *.lst *.rst *.rel *.sym *.map *.lk *.cdb *.adb *.mem *.noi

.PHONY: all clean
.PRECIOUS: %.ihx
