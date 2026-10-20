/* bank.c - the bank registers (RESPIN 22; the data map of RESPIN 28).  The
 * upper 16K words of the code space are a window on one of 64 code banks:
 * 0x215 (fetches above word 0x4000).  The data space has three regions,
 * by address whatever the form of the access: below 0x2000 the common 8K
 * (physical 0), 0x2000-0x3fff the data window on one of 32 granules of 8K
 * (0x216, 5 bits), 0x4000 up the stack window on one of 16 banks of 16K
 * (0x217, 4 bits; bank n is granules 2n and 2n+1).  All three reset to 1 =
 * the TT07 layout, physical 0-32K flat: granule 0 through the data window
 * is the common 8K itself, bank 0 through the stack window the common 8K
 * and granule 1.  Needs the cache on (CACHE=1: the banks are PSRAM) and the
 * image bank_test.hex: this program at 0 and a two-word routine `ldi #bank;
 * ret` at word 0x4000 of code banks 1, 2, 3, 37 and 63 (flash bytes 0x8000,
 * 0x10000, 0x18000, 0x128000, 0x1f8000: bank_stubs.hex).  Built with the
 * stack at 0x7fff, so the program's own frames run in stack bank 1. */
#include "harness.h"

__sfr __at(0x215) CODE_BANK;
__sfr __at(0x216) DATA_BANK;
__sfr __at(0x217) STACK_BANK;

static unsigned char sb_pop;      /* what a stack in another bank gave back */
static unsigned char scratch;     /* a byte in the common 8K for the helpers */

/* a byte through IX: stax / ldax n(ix) (the frames as sdcc --rev2 lays
 * them out: SP at the top byte) */
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

/* the same in stack bank `bank`: the program's own stack is out of reach
 * while the bank is switched, so the arguments are read first and the
 * value passes through the common 8K */
static unsigned char peek_sb(unsigned int a, unsigned char bank) __naked
{
  __asm
    ldxx 0(sp)
    ldax 2(sp)
    sta 0x217
    ldax 0(ix)
    sta _scratch
    ldi #1
    sta 0x217
    lda _scratch
    ret
  __endasm;
}

static void poke_sb(unsigned int a, unsigned char bank, unsigned char v) __naked
{
  __asm
    ldax 3(sp)
    sta _scratch
    ldxx 0(sp)
    ldax 2(sp)
    sta 0x217
    lda _scratch
    stax 0(ix)
    ldi #1
    sta 0x217
    ret
  __endasm;
}

/* the stack bank register's width, read back while the stack is elsewhere */
static unsigned char sb_width(void) __naked
{
  __asm
    ldi #0x1f
    sta 0x217
    lda 0x217
    sta _scratch
    ldi #1
    sta 0x217
    lda _scratch
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
    ldx #0x3000
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

/* a stack in the data window: with SP at 0x3e00 the pushes go to the data
 * bank's granule (a thread's stack in its heap) */
static void stack_in_granule3(void) __naked
{
  __asm
    ldx #0x3e00
    xchg sp              ; SP = 0x3e00 (granule 1), IX = the caller's SP
    push ix              ; ... kept at 0x3dfe/0x3dff of granule 1
    ldi #3
    sta 0x216            ; data bank 3: 0x3dfd down is in granule 3 now
    ldi #0x5a
    push a               ; granule 3, 0x3dfd
    ldi #0xa5
    push a               ; granule 3, 0x3dfc
    pop a
    sta _sb_pop
    ldi #1
    sta 0x216            ; data bank 1 again, SP = 0x3dfd
    ads #1
    pop ix
    xchg sp
    ret
  __endasm;
}

void main(void)
{
  unsigned char i;

  /* the registers: reset 1; five bits, four bits, six bits */
  CHECK(1, CODE_BANK == 1 && DATA_BANK == 1 && STACK_BANK == 1);
  DATA_BANK = 0x3f;
  CHECK(2, DATA_BANK == 0x1f);
  DATA_BANK = 1;
  CHECK(3, sb_width() == 0x0f && STACK_BANK == 1);
  CODE_BANK = 0xff;                     /* written from the common area, nothing above 0x4000 runs here */
  CHECK(4, CODE_BANK == 0x3f);
  CODE_BANK = 1;

  /* the code bank: the routine at word 0x4000 of banks 2, 3, 1, 37, 63 */
  CODE_BANK = 2;
  CHECK(5, call_upper() == 0x22);
  CODE_BANK = 3;
  CHECK(6, call_upper() == 0x33);
  CODE_BANK = 1;
  CHECK(7, call_upper() == 0x11);
  CODE_BANK = 37;                       /* banks above 15: flash byte 37 * 0x8000 */
  CHECK(8, call_upper() == 0x25);
  CODE_BANK = 63;
  CHECK(9, call_upper() == 0x3f);
  CODE_BANK = 1;
  CHECK(10, call_after_switch(3) == 0x33);
  CHECK(11, call_after_switch(2) == 0x22);
  CHECK(12, call_after_switch(1) == 0x11);

  /* the data window: one address, three granules, through the cache */
  DATA_BANK = 2;
  poke(0x3000, 0x22);
  DATA_BANK = 3;
  poke(0x3000, 0x33);
  DATA_BANK = 4;
  poke(0x3000, 0x44);
  CHECK(13, peek(0x3000) == 0x44);
  DATA_BANK = 3;
  CHECK(14, peek(0x3000) == 0x33);
  DATA_BANK = 2;
  CHECK(15, peek(0x3000) == 0x22);
  DATA_BANK = 1;

  /* back to back: the write of the data bank and the access it applies to */
  CHECK(16, peek_after_switch(2) == 0x22);
  CHECK(17, peek_after_switch(3) == 0x33);
  CHECK(18, peek_after_switch(4) == 0x44);
  DATA_BANK = 1;

  /* granule 0 through the data window is the common 8K itself */
  poke(0x0100, 0x5a);
  DATA_BANK = 0;
  CHECK(19, peek(0x2100) == 0x5a);
  poke(0x2100, 0xa5);
  DATA_BANK = 1;
  CHECK(20, peek(0x0100) == 0xa5);

  /* granule 1 (the data bank at reset) is the upper half of bank 0: the
   * same byte through the stack window with the stack bank 0.  The two
   * windows have their own cache lines (the index is address bit 14), so
   * a byte written through one is seen through the other once its line
   * is written back: evict it with another line of the same index first
   * (the same address bits 5:4 in the same window) */
  poke(0x2345, 0x77);
  poke(0x2745, 0);                      /* evicts 0x2345's line (dirty: written back) */
  peek(0x2745);
  CHECK(21, peek_sb(0x6345, 0) == 0x77);

  /* granule 2 is the lower half of bank 1: one byte, two addresses */
  poke(0x5000, 0x11);
  poke(0x7000, 0);                      /* evicts 0x5000's line */
  DATA_BANK = 2;
  CHECK(22, peek(0x3000) == 0x11);
  poke(0x3000, 0x12);
  poke(0x3400, 0);                      /* evicts 0x3000's line */
  DATA_BANK = 1;
  peek_sb(0x7000, 2);                   /* and the stale line of 0x5000 (index 4): another bank's same index */
  CHECK(23, peek(0x5000) == 0x12);

  /* the stack window goes by address: an IX access there sees the stack
   * bank whatever the data bank, and another stack bank is another byte */
  DATA_BANK = 4;
  CHECK(24, peek(0x5000) == 0x12);
  DATA_BANK = 1;
  poke_sb(0x5000, 2, 0x22);
  poke_sb(0x5000, 3, 0x33);
  CHECK(25, peek_sb(0x5000, 2) == 0x22 && peek_sb(0x5000, 3) == 0x33);
  CHECK(26, peek(0x5000) == 0x12 && peek_sb(0x5000, 1) == 0x12);

  /* evictions: lines of granules 4 and 5 (bank 2's halves) take turns in
   * the same cache line (0x3000 + i * 0x40 all map to line 4), written
   * back to their granules */
  for (i = 0; i < 8; i++) {
    DATA_BANK = 4;
    poke(0x3000 + i * 0x40, i);
    DATA_BANK = 5;
    poke(0x3000 + i * 0x40, 0x80 + i);
  }
  for (i = 0; i < 8; i++) {
    DATA_BANK = 4;
    if (peek(0x3000 + i * 0x40) != i) fails++;
    DATA_BANK = 5;
    if (peek(0x3000 + i * 0x40) != 0x80 + i) fails++;
  }
  DATA_BANK = 1;
  CHECK(27, fails == 0);
  /* ... and bank 2 through the stack window shows them (written back by
   * the evictions above): granule 4 is its lower half, granule 5 its
   * upper */
  DATA_BANK = 4;
  poke(0x3480, 0);                      /* the last lines of the loop out */
  DATA_BANK = 5;
  poke(0x3480, 0);
  DATA_BANK = 1;
  CHECK(28, peek_sb(0x5040, 2) == 1 && peek_sb(0x7040, 2) == 0x81);

  /* the stack bank: the two pushes landed in bank 2, bank 1 untouched */
  poke(0x7efc, 0);
  poke(0x7efd, 0);
  stack_in_bank2();
  CHECK(29, sb_pop == 0xa5);
  CHECK(30, STACK_BANK == 1);
  CHECK(31, peek_sb(0x7efc, 2) == 0xa5 && peek_sb(0x7efd, 2) == 0x5a);
  CHECK(32, peek(0x7efc) == 0 && peek(0x7efd) == 0);

  /* a stack in the data window: the pushes landed in granule 3 */
  DATA_BANK = 3;
  poke(0x3dfc, 0);
  poke(0x3dfd, 0);
  DATA_BANK = 1;
  poke(0x3dfc, 0);
  poke(0x3dfd, 0);
  stack_in_granule3();
  CHECK(33, sb_pop == 0xa5 && DATA_BANK == 1);
  DATA_BANK = 3;
  CHECK(34, peek(0x3dfc) == 0xa5 && peek(0x3dfd) == 0x5a);
  DATA_BANK = 1;
  CHECK(35, peek(0x3dfc) == 0 && peek(0x3dfd) == 0);
  DONE();
}
