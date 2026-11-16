/* misc40.c - RESPIN 40: the 16 x 16 multiplier (lisa_mul16.v), sleep,
 * UART2's transmit FIFO / RS-485 direction / idle timer (lisa_uart.v), the
 * high-speed counters (lisa_hsc.v) and the SP limit fault (lisa_splim.v).
 * test.py (make MISC40=1) drives the pins: two bytes into UART2 on ui_in[2],
 * quadrature on ui_in[1:0] (HSC0), pulses with a direction on ui_in[5:4]
 * (HSC1; ui_in[7] stays low: high, it makes the debug UART's divider ui_in[6:0]); it decodes UART2's transmit on uo[2] and watches DE on uo[7]
 * (both in uo mux 2, set by test.py through debug register 0x1b).
 *
 * First run (the SP fault's FAULT clear):
 *  1-4 MUL16: unsigned, signed, 0x8000 x 0x8000, accumulate
 *  5   sleep: Timer 1 wakes the core through vector 1; the cycle counter
 *      shows it slept
 *  6-8 UART2: eight bytes queued without a wait, TX_IDLE after them (DE on
 *      uo[7] meanwhile, checked by test.py); the idle timer sets IDLE_FLAG
 *      after the second received byte and not before; IDLE_CLR clears it
 *  11-13 HSC0 in x4 then x1 quadrature (75 transitions, then 19 cycles: CMP / MATCH / GE
 *      and the vector-10 interrupt, twice: the count crosses 300 going up
 *      and lands on it coming back), HSC1 counting pulses with a direction
 *  14  the SP limit in interrupt mode (vector 11) under a recursion
 *  then the SP limit in reset mode: the recursion resets the chip
 * Second run (FAULT set):
 *  9, 10 FAULT set and EN clear after the reset; a 1 clears FAULT
 */
#include "harness.h"
#include <tt07.h>

__sfr __at(0x248) CYC0;
__sfr __at(0x249) CYC1;
__sfr __at(0x24A) CYC2;
__sfr __at(0x24B) CYC3;

__sfr __at(0x270) MUL_A_L;
__sfr __at(0x271) MUL_A_H;
__sfr __at(0x272) MUL_B_L;
__sfr __at(0x273) MUL_B_H;
__sfr __at(0x274) MUL_P0;
__sfr __at(0x275) MUL_P1;
__sfr __at(0x276) MUL_P2;
__sfr __at(0x277) MUL_P3;
__sfr __at(0x278) MUL_CTRL;

__sfr __at(0x27A) SPL_L;
__sfr __at(0x27B) SPL_M;
__sfr __at(0x27C) SPL_H;
__sfr __at(0x27D) SPL_CTRL;

__sfr __at(0x260) HSC0_CTRL;
__sfr __at(0x261) HSC0_STAT;
__sfr __at(0x262) HSC0_CNT_L;
__sfr __at(0x263) HSC0_CNT_H;
__sfr __at(0x264) HSC0_CMP_L;
__sfr __at(0x265) HSC0_CMP_H;
__sfr __at(0x268) HSC1_CTRL;
__sfr __at(0x269) HSC1_STAT;
__sfr __at(0x26A) HSC1_CNT_L;
__sfr __at(0x26B) HSC1_CNT_H;

__sfr __at(0x216) UART2_IDLE;
__sfr __at(0x217) UART2_CTRL;
__sfr __at(0x21E) UART2_DIV;

#define SLEEP() __asm__ ("sleep")

volatile unsigned char t1_irqs, hsc_irqs, spl_irqs;

void t1_isr(void) __interrupt(1)
{
  t1_irqs++;
  INT_STATUS = 1;                       /* acknowledge */
  TIMER1_CTRL = 0;                      /* one is enough */
}

void hsc_isr(void) __interrupt(10)
{
  hsc_irqs++;
  HSC0_STAT = 0x07;                     /* MATCH / OVF / UNF cleared */
}

void spl_isr(void) __interrupt(11)
{
  spl_irqs++;
  SPL_CTRL = 0x08;                      /* FAULT cleared, EN and IE off */
}

static unsigned long cycles(void)
{
  unsigned long v = CYC0;               /* latches 31:8 */
  v |= (unsigned long)CYC1 << 8;
  v |= (unsigned long)CYC2 << 16;
  v |= (unsigned long)CYC3 << 24;
  return v;
}

static unsigned long mul(unsigned int a, unsigned int b, unsigned char ctrl)
{
  unsigned long p;
  MUL_CTRL = ctrl;
  MUL_A_L = a;
  MUL_A_H = a >> 8;
  MUL_B_L = b;
  MUL_B_H = b >> 8;                     /* starts */
  while (MUL_CTRL & 0x80)
    ;
  p = MUL_P0;
  p |= (unsigned long)MUL_P1 << 8;
  p |= (unsigned long)MUL_P2 << 16;
  p |= (unsigned long)MUL_P3 << 24;
  return p;
}

static unsigned int hsc0(void)
{
  unsigned char lo = HSC0_CNT_L;        /* latches the high byte */
  return ((unsigned int)HSC0_CNT_H << 8) | lo;
}

static unsigned int hsc1(void)
{
  unsigned char lo = HSC1_CNT_L;
  return ((unsigned int)HSC1_CNT_H << 8) | lo;
}

/* a count that has started and then not changed for 20000 clocks */
static unsigned int settled(unsigned int (*rd)(void))
{
  unsigned int v, last;
  unsigned long t;
  do
    v = rd();
  while (v == 0);
  do {
    last = v;
    t = cycles();
    while (cycles() - t < 20000)
      ;
    v = rd();
  } while (v != last);
  return v;
}

static unsigned char recurse(unsigned char n)
{
  volatile unsigned char pad[2];
  pad[0] = n;
  pad[1] = 0;
  if (n)
    return recurse(n - 1) + pad[0] + pad[1];
  return 0;
}

void main(void)
{
  unsigned long t, u;
  unsigned char i, waits, b0, b1, flag0;
  unsigned int n;

  if (SPL_CTRL & 0x08) {
    /* the second run: the SP limit fault reset the chip */
    puts("sp fault reset\n");
    CHECK(9, (SPL_CTRL & 0x01) == 0);
    SPL_CTRL = 0x08;
    CHECK(10, (SPL_CTRL & 0x08) == 0);
    DONE();
    for (;;)
      ;
  }

  puts("misc40\n");

  /* 1-4: the multiplier */
  CHECK(1, mul(0x1234, 0x5678, 0x00) == 0x06260060UL);
  CHECK(2, mul(0xFFFE, 0x0003, 0x01) == 0xFFFFFFFAUL);
  CHECK(3, mul(0x8000, 0x8000, 0x01) == 0x40000000UL);
  MUL_CTRL = 0x04;                      /* CLR */
  mul(2, 3, 0x03);
  mul(4, 5, 0x03);
  mul(0xFFFF, 7, 0x03);                 /* -1 x 7 */
  CHECK(4, mul(0, 0, 0x03) == 19UL && (MUL_CTRL & 0x80) == 0);

  /* 5: sleep until Timer 1's rollover: 1000 clocks a tick, 20 ticks */
  TIMER1_PREDIV_LO = 999 & 0xFF;
  TIMER1_PREDIV_HI = 999 >> 8;
  TIMER1_DIV_LO = 20;
  TIMER1_DIV_HI = 0;
  INT_STATUS = 1;
  INT_ENABLE = 0x01;
  lisa_ei();
  TIMER1_CTRL = 1;
  t = cycles();
  SLEEP();
  u = cycles();
  CHECK(5, t1_irqs == 1 && u - t > 15000 && u - t < 60000);
  INT_ENABLE = 0;

  /* 6-8: UART2 at a bit of 32 clocks, DE on uo[7] */
  UART2_DIV = 0;
  UART2_STATUS = 0x04;                  /* no autobaud: the divisor rules */
  UART2_CTRL = 0x01;                    /* DE_EN */
  waits = 0;
  for (i = 0; i < 8; i++) {
    while (!(UART2_STATUS & 0x02))
      waits++;
    UART2_DATA = 'A' + i;
  }
  CHECK(6, waits == 0);
  t = cycles();
  while (!(UART2_STATUS & 0x10) && cycles() - t < 20000)
    ;
  CHECK(7, (UART2_STATUS & 0x10) && (UART2_STATUS & 0x40) == 0);

  UART2_IDLE = 40;                      /* 40 bit times of silence (3.5 characters) */
  for (n = 0; n < 60000 && !(UART2_STATUS & 0x01); n++)
    ;
  b0 = UART2_DATA;
  for (n = 0; n < 60000 && !(UART2_STATUS & 0x01); n++)
    ;
  b1 = UART2_DATA;
  flag0 = UART2_STATUS & 0x20;          /* just after the byte: not yet (40 bits = 1280 clocks away) */
  for (n = 0; n < 60000 && !(UART2_STATUS & 0x20); n++)
    ;
  i = UART2_STATUS & 0x20;
  UART2_CTRL = 0x05;                    /* IDLE_CLR, DE_EN kept */
  CHECK(8, b0 == 0x55 && b1 == 0xAA && flag0 == 0 && i && (UART2_STATUS & 0x20) == 0);

  /* 11-13: the high-speed counters.  HSC0: quadrature x4 on ui_in[1:0],
     compare at 300 with the interrupt; HSC1: pulses on ui_in[4] with
     ui_in[5] the direction */
  HSC0_CMP_L = 75;                      /* 100 transitions forward, 25 back: x4 counts every one */
  HSC0_CMP_H = 0;
  HSC0_CTRL = 0x73;                     /* CLR, IE, EN, pins 0, x4 */
  HSC1_CTRL = 0x59;                     /* CLR, EN, pins 2 (ui_in[5:4]), pulse + direction */
  n = settled(hsc0);
  puts("hsc0 cnt/stat/irqs ");
  puthex(n);
  putc(' ');
  puthex(HSC0_STAT);
  putc(' ');
  puthex(hsc_irqs);
  putc('\n');
  /* the count lands on 75 twice: on the way up to 100 and coming back */
  CHECK(11, n == 75 && (HSC0_STAT & 0x40) && hsc_irqs == 2 && (HSC0_STAT & 0x01) == 0);
  n = settled(hsc1);
  puts("hsc1 cnt/stat ");
  puthex(n);
  putc(' ');
  puthex(HSC1_STAT);
  putc('\n');
  CHECK(12, n == 30 && (HSC1_STAT & 0x08));
  HSC0_CTRL = 0x52;                     /* CLR, EN, x1: the second burst, a count a cycle */
  n = settled(hsc0);                    /* 100 transitions = 25 cycles up, 25 = 6 cycles back */
  CHECK(13, n == 19);
  HSC0_CTRL = 0;
  HSC1_CTRL = 0;

  /* 14: the SP limit in interrupt mode.  The stack starts at 0x7F (the
     128-byte RAM, the cache off, the globals at its bottom); five frames of
     the recursion take it below 0x60 and no further than the globals */
  SPL_L = 0x60;
  SPL_M = 0;
  SPL_H = 0;
  SPL_CTRL = 0x05;                      /* EN, IE */
  recurse(5);
  puts("spl irqs/ctrl ");
  puthex(spl_irqs);
  putc(' ');
  puthex(SPL_CTRL);
  putc('\n');
  CHECK(14, spl_irqs == 1 && (SPL_CTRL & 0x09) == 0);
  lisa_di();

  /* then in reset mode: the chip restarts and finds FAULT */
  puts("waiting for the sp fault\n");
  SPL_CTRL = 0x03;                      /* EN, RST_ACT */
  recurse(5);
  puts("no reset\n");
  for (;;)
    ;
}
