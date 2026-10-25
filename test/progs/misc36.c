/* misc36.c - RESPIN 36: the cycle counter (lisa_cyccnt.v), the watchdog
 * (lisa_wdt.v) and the PDM outputs (lisa_pdm.v).
 *
 * First run (WDRST clear):
 *  1 the cycle counter counts: a loop of known length, CYC0 latching 31:8
 *  2 a write clears it
 *  3 the watchdog kicked every 60000 clocks with a timeout of 2 x 65536
 *    (SCALE 0, TIMEOUT 1) does not fire through five kicks; then it is not
 *    kicked: it resets the core and the peripherals and the program starts
 *    again
 * Second run (WDRST set):
 *  4 WDRST set, EN clear; a 1 written clears WDRST
 *  5 the PDM channels at 64 and 192 (25% and 75%: test.py measures them on
 *    uo[1] / uo[2], mux 2) - left running
 */
#include "harness.h"

__sfr __at(0x248) CYC0;
__sfr __at(0x249) CYC1;
__sfr __at(0x24A) CYC2;
__sfr __at(0x24B) CYC3;
__sfr __at(0x24C) WDT_CTRL;
__sfr __at(0x24D) WDT_KICK;
__sfr __at(0x24E) WDT_TIMEOUT;
__sfr __at(0x24F) WDT_STAT;
__sfr __at(0x250) PDM_CTRL;
__sfr __at(0x251) PDM_VAL0;
__sfr __at(0x252) PDM_VAL1;

static unsigned long cycles(void)
{
  unsigned long v = CYC0;              /* latches 31:8 */
  v |= (unsigned long)CYC1 << 8;
  v |= (unsigned long)CYC2 << 16;
  v |= (unsigned long)CYC3 << 24;
  return v;
}

static void wait_cycles(unsigned long n)
{
  unsigned long t = cycles();
  while (cycles() - t < n)
    ;
}

void main(void)
{
  unsigned long a, b;
  unsigned char i;

  if (WDT_STAT & 1) {
    /* the second run: the watchdog fired */
    puts("watchdog reset\n");
    CHECK(4, (WDT_CTRL & 1) == 0 && ((WDT_STAT = 1), (WDT_STAT & 1) == 0));
    PDM_VAL0 = 64;
    PDM_VAL1 = 192;
    PDM_CTRL = 3;
    CHECK(5, PDM_CTRL == 3 && PDM_VAL0 == 64 && PDM_VAL1 == 192);
    DONE();
    for (;;)
      ;
  }

  puts("misc36\n");
  a = cycles();
  for (i = 0; i < 100; i++)
    ;
  b = cycles();
  CHECK(1, b > a && b - a > 200 && b - a < 200000);

  CYC0 = 0;
  a = cycles();
  CHECK(2, a < 1000);

  WDT_TIMEOUT = 1;                     /* 2 ticks of 65536 clocks */
  WDT_CTRL = 1;                        /* EN, SCALE 0 */
  for (i = 0; i < 5; i++) {
    wait_cycles(60000);
    WDT_KICK = 0xA5;
  }
  CHECK(3, (WDT_CTRL & 1) == 1);
  puts("waiting for the watchdog\n");
  for (;;)
    ;
}
