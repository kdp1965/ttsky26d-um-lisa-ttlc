/* plc.c - RESPIN 40: the PLC timer / counter block (lisa_plc.v) from the
 * core, and its setup for the ladder program progs/ttlc/ttlc_plc.asm that
 * test.py (make PLC=1) then runs on the MC14500B against the testbench's
 * I/O chains.
 *
 *  1-3 the blocks' registers read back (T0 TON 100 ticks, T1 TOF 100
 *      ticks, C0 up to 3; the tick 500 clocks: TC_PRE 499)
 *  4,5 T2 driven by LISA_IN: Q 2 ticks after IN, clear when IN drops
 *  6,7 C1 counted by LISA_CU's edges, Q at 2, RST clears it
 *  8   the storage bytes 24-31 (bits 64-127) through TIDX / TDATA, the
 *      index wrapping at 31
 * The ladder's timing (T0 / T1 100 ticks = 50000 clocks, C0's three pulses,
 * the storage loopback) is checked by test.py on the chains after the
 * program is done.
 */
#include "harness.h"

__sfr __at(0x248) CYC0;
__sfr __at(0x249) CYC1;
__sfr __at(0x24A) CYC2;
__sfr __at(0x24B) CYC3;

__sfr __at(0x250) TC_IDX;
__sfr __at(0x251) TC_CTRL;
__sfr __at(0x252) TC_PRESET_L;
__sfr __at(0x253) TC_PRESET_H;
__sfr __at(0x254) TC_VALUE_L;
__sfr __at(0x255) TC_VALUE_H;
__sfr __at(0x256) T_DONE;
__sfr __at(0x257) C_DONE;
__sfr __at(0x258) TC_PRE_L;
__sfr __at(0x259) TC_PRE_H;

__sfr __at(0x22C) TIDX;
__sfr __at(0x22D) TDATA;

static unsigned long cycles(void)
{
  unsigned long v = CYC0;
  v |= (unsigned long)CYC1 << 8;
  v |= (unsigned long)CYC2 << 16;
  v |= (unsigned long)CYC3 << 24;
  return v;
}

/* wait up to n clocks for (reg & mask) == want; 1 if it got there */
static unsigned char wait_for(unsigned char which, unsigned char mask, unsigned char want, unsigned long n)
{
  unsigned long t = cycles();
  unsigned char v;
  do {
    v = which ? C_DONE : T_DONE;
    if ((v & mask) == want)
      return 1;
  } while (cycles() - t < n);
  return 0;
}

static void block(unsigned char idx, unsigned char ctrl, unsigned int preset)
{
  TC_IDX = idx;
  TC_PRESET_L = preset;
  TC_PRESET_H = preset >> 8;
  TC_CTRL = ctrl;
}

static unsigned int value(unsigned char idx)
{
  unsigned char lo;
  TC_IDX = idx;
  lo = TC_VALUE_L;                      /* latches the high byte */
  return ((unsigned int)TC_VALUE_H << 8) | lo;
}

void main(void)
{
  unsigned char ok;

  puts("plc\n");
  TC_PRE_L = 499 & 0xFF;                /* a tick every 500 clocks */
  TC_PRE_H = 499 >> 8;
  block(0, 0x00, 100);                  /* T0: TON, base 1 ms, 100 ticks */
  block(1, 0x01, 100);                  /* T1: TOF, 100 ticks */
  block(8, 0x00, 3);                    /* C0: up, 3 */
  TC_IDX = 0;
  CHECK(1, TC_IDX == 0 && (TC_CTRL & 0x07) == 0x00 && TC_PRESET_L == 100 && TC_PRESET_H == 0);
  TC_IDX = 1;
  CHECK(2, (TC_CTRL & 0x07) == 0x01 && TC_PRESET_L == 100);
  TC_IDX = 8;
  CHECK(3, (TC_CTRL & 0x01) == 0x00 && TC_PRESET_L == 3 && TC_PRE_L == (499 & 0xFF) && TC_PRE_H == (499 >> 8));

  /* 4, 5: T2 from LISA_IN, two ticks */
  block(2, 0x00, 2);
  TC_IDX = 2;
  TC_CTRL = 0x20;                       /* LISA_IN */
  ok = wait_for(0, 0x04, 0x04, 4000);   /* 2 ticks = 1000 clocks, a scan margin */
  CHECK(4, ok && value(2) == 2 && (TC_CTRL & 0x18) == 0x18);
  TC_CTRL = 0x00;
  ok = wait_for(0, 0x04, 0x00, 1000);
  CHECK(5, ok && value(2) == 0);

  /* 6, 7: C1 from LISA_CU's rising edges */
  block(9, 0x00, 2);
  TC_IDX = 9;
  TC_CTRL = 0x20;
  TC_CTRL = 0x00;
  CHECK(6, (C_DONE & 0x02) == 0 && value(9) == 1);
  TC_IDX = 9;
  TC_CTRL = 0x20;
  CHECK(7, (C_DONE & 0x02) != 0 && value(9) == 2 && ((TC_CTRL = 0x40), (C_DONE & 0x02) == 0) && value(9) == 0);

  /* 8: storage bits 64-127 as bytes 24-31 (bytes 25 and 30: the ladder
     running beside this program writes bits 64, 120 and 127 every scan) */
  TIDX = 25;
  TDATA = 0x5A;                         /* bits 72-79; TIDX -> 26 */
  TIDX = 30;
  TDATA = 0xA5;                         /* bits 112-119; TIDX -> 31 */
  TIDX = 25;
  ok = TDATA == 0x5A;
  TIDX = 30;
  ok = ok && TDATA == 0xA5 && TIDX == 31;
  (void) TDATA;                         /* byte 31: the read moves TIDX on, 31 wraps to 0 */
  ok = ok && TIDX == 0;
  TIDX = 30;
  TDATA = 0;
  TIDX = 25;
  TDATA = 0;
  CHECK(8, ok);

  DONE();
  for (;;)
    ;
}
