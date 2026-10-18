/* bank.c - the bank registers (RESPIN 22).  The upper 16K of the code space
 * and of the data space are windows on one of 16 banks: 0x215 = the code
 * bank (fetches above word 0x4000), 0x216 = the data bank (IX-relative
 * accesses above 0x4000: C pointers, the debugger), 0x217 = the stack bank
 * (SP-relative accesses above 0x4000).  All three reset to 1 = the TT07
 * layout; bank 0 is the lower half itself.  Needs the cache on (CACHE=1:
 * the banks are PSRAM) and the image bank_test.hex: this program at 0 and
 * a two-word routine `ldi #bank; ret` at word 0x4000 of banks 1, 2 and 3
 * (flash bytes 0x8000, 0x10000, 0x18000: bank_stubs.hex).  Built with the
 * stack at 0x7fff, so the program's own frames run in stack bank 1. */
#include "harness.h"

__sfr __at(0x215) CODE_BANK;
__sfr __at(0x216) DATA_BANK;
__sfr __at(0x217) STACK_BANK;

static unsigned char sb_pop;      /* what the stack in bank 2 gave back */

/* a byte through IX: stax / ldax n(ix) see the data bank above 0x4000
 * (the frames as sdcc --rev2 lays them out: SP at the top byte) */
static void poke(unsigned int a, unsigned char v) __naked
{
  __asm
    ldxx 0(sp)
    ldax 2(sp)
    stax 0(ix)
    ret
  __endasm;
}

static unsigned char peek(unsigned int a) __naked
{
  __asm
    ldxx 0(sp)
    ldax 0(ix)
    ret
  __endasm;
}

/* call word 0x4000: the routine there returns its bank's number in A */
static unsigned char call_upper(void) __naked
{
  __asm
    sra
    ldx #0x4000
    call ix
    lra
    ret
  __endasm;
}

/* a switch takes effect on the next instruction: the write of the data
 * bank right before the load, of the code bank right before the call
 * (the bank in A: the first byte parameter) */
static unsigned char peek_after_switch(unsigned char bank) __naked
{
  __asm
    ldx #0x5000
    sta 0x216
    ldax 0(ix)
    ret
  __endasm;
}

static unsigned char call_after_switch(unsigned char bank) __naked
{
  __asm
    sra
    ldx #0x4000
    sta 0x215
    call ix
    lra
    ret
  __endasm;
}

/* the stack bank: with SP at 0x7f00, push two bytes while the stack bank
 * is 2 and pop one back; the caller's SP waits in bank 1 meanwhile */
static void stack_in_bank2(void) __naked
{
  __asm
    ldx #0x7f00
    xchg sp              ; SP = 0x7f00 (bank 1), IX = the caller's SP
    push ix              ; ... kept at 0x7efe/0x7eff of bank 1
    ldi #2
    sta 0x217            ; stack bank 2: 0x7efd down is in bank 2 now
    ldi #0x5a
    push a               ; bank 2, 0x7efd
    ldi #0xa5
    push a               ; bank 2, 0x7efc
    pop a                ; back from bank 2
    sta _sb_pop
    ldi #1
    sta 0x217            ; stack bank 1 again, SP = 0x7efd
    ads #1               ; past the byte left in bank 2
    pop ix               ; the caller's SP
    xchg sp
    ret
  __endasm;
}

void main(void)
{
  unsigned char i;

  /* the registers: reset 1, four bits wide */
  CHECK(1, CODE_BANK == 1 && DATA_BANK == 1 && STACK_BANK == 1);
  DATA_BANK = 0x1f;
  CHECK(2, DATA_BANK == 0x0f);
  DATA_BANK = 1;

  /* the code bank: the routine at word 0x4000 of banks 2, 3 and 1 */
  CODE_BANK = 2;
  CHECK(3, call_upper() == 0x22);
  CODE_BANK = 3;
  CHECK(4, call_upper() == 0x33);
  CODE_BANK = 1;
  CHECK(5, call_upper() == 0x11);

  /* the data bank: one address, three banks, through the cache */
  DATA_BANK = 1;
  poke(0x5000, 0x11);
  DATA_BANK = 2;
  poke(0x5000, 0x22);
  DATA_BANK = 3;
  poke(0x5000, 0x33);
  CHECK(6, peek(0x5000) == 0x33);
  DATA_BANK = 2;
  CHECK(7, peek(0x5000) == 0x22);
  DATA_BANK = 1;
  CHECK(8, peek(0x5000) == 0x11);
  /* bank 0 through the upper window is the lower half itself */
  poke(0x0100, 0x5a);
  DATA_BANK = 0;
  CHECK(9, peek(0x4100) == 0x5a);
  poke(0x4100, 0xa5);
  DATA_BANK = 1;
  CHECK(10, peek(0x0100) == 0xa5);

  /* evictions: lines of banks 2 and 3 take turns in the same cache line
   * (0x6000 + i * 0x40 all map to line 4), written back to their banks */
  for (i = 0; i < 8; i++) {
    DATA_BANK = 2;
    poke(0x6000 + i * 0x40, i);
    DATA_BANK = 3;
    poke(0x6000 + i * 0x40, 0x80 + i);
  }
  for (i = 0; i < 8; i++) {
    DATA_BANK = 2;
    if (peek(0x6000 + i * 0x40) != i) fails++;
    DATA_BANK = 3;
    if (peek(0x6000 + i * 0x40) != 0x80 + i) fails++;
  }
  DATA_BANK = 1;
  CHECK(11, fails == 0);

  /* back to back: the write and the access it applies to */
  CHECK(17, peek_after_switch(2) == 0x22);
  CHECK(18, peek_after_switch(3) == 0x33);
  CHECK(19, peek_after_switch(1) == 0x11);
  CHECK(20, call_after_switch(3) == 0x33);
  CHECK(21, call_after_switch(2) == 0x22);
  CHECK(22, call_after_switch(1) == 0x11);

  /* the stack bank: the two pushes landed in bank 2, bank 1 untouched */
  poke(0x7efc, 0);
  poke(0x7efd, 0);
  stack_in_bank2();
  CHECK(12, sb_pop == 0xa5);
  CHECK(13, STACK_BANK == 1);
  DATA_BANK = 2;
  CHECK(14, peek(0x7efc) == 0xa5 && peek(0x7efd) == 0x5a);
  DATA_BANK = 1;
  CHECK(15, peek(0x7efc) == 0 && peek(0x7efd) == 0);
  DATA_BANK = 2;
  CHECK(16, peek(0x7efd) == 0x5a);
  DATA_BANK = 1;
  DONE();
}
