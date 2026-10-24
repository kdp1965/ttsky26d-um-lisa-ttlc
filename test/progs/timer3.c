/* timer3.c - Timer 3 (RESPIN 32, src/lisa_timer3.v): a 16-bit timer with a
 * prescaler, two compares driving PWM0 / PWM1 (uo[1] / uo[2] in mux 2) and
 * two input captures (ui_in[4] / ui_in[5]), its interrupt source 8 on
 * vector 9.  The testbench drives a square wave of 2 x 3000 clocks on both
 * capture inputs (tb.v cap_period) and, after the run, measures the PWM
 * pins' duty (pwm_high0 / pwm_high1): the program leaves PWM0 at 25% and
 * PWM1 at 75% of a 100-clock period running.
 *
 *  1 the registers' reset values and readback
 *  2 a 16-bit count written and read back (the high byte latched)
 *  3 the plain timer: OVF after (TOP + 1) x (PRE + 1) clocks, cleared by a 1
 *  4 the compare flag
 *  5 the captures: a rising edge 6000 clocks after the last, a falling one
 *    3000 after it (+-2: the synchroniser and the edge's clock; the half
 *    period is long enough for the polling to see each edge)
 *  6 the interrupt on vector 9 (__interrupt(9)): OVF requests it, the
 *    handler acknowledges in STATUS
 *  7 no request with the event's IE bit clear */
#include "harness.h"
#include <tt07.h>

__sfr __at(0x230) T3_PRE;
__sfr __at(0x231) T3_TOP_L;
__sfr __at(0x232) T3_TOP_H;
__sfr __at(0x233) T3_CNT_L;
__sfr __at(0x234) T3_CNT_H;
__sfr __at(0x235) T3_CMP0_L;
__sfr __at(0x236) T3_CMP0_H;
__sfr __at(0x237) T3_CMP1_L;
__sfr __at(0x238) T3_CMP1_H;
__sfr __at(0x239) T3_CAP0_L;
__sfr __at(0x23A) T3_CAP0_H;
__sfr __at(0x23B) T3_CAP1_L;
__sfr __at(0x23C) T3_CAP1_H;
__sfr __at(0x23D) T3_CTRL;
__sfr __at(0x23E) T3_IE;
__sfr __at(0x23F) T3_STATUS;

#define EN        0x01
#define PWM0      0x02
#define PWM1      0x04
#define CAP0_RISE 0x10
#define CAP1_FALL 0x80

#define F_OVF     0x01
#define F_CMP0    0x02
#define F_CMP1    0x04
#define F_CAP0    0x08
#define F_CAP1    0x10

volatile unsigned char t3_irqs;

void timer3_isr(void) __interrupt(9)
{
  t3_irqs++;
  T3_STATUS = F_OVF;            /* acknowledge */
}

static unsigned int cnt(void)
{
  unsigned char lo = T3_CNT_L;  /* latches the high byte */
  return ((unsigned int)T3_CNT_H << 8) | lo;
}

static unsigned int cap0(void)
{
  return ((unsigned int)T3_CAP0_H << 8) | T3_CAP0_L;
}

static unsigned int cap1(void)
{
  return ((unsigned int)T3_CAP1_H << 8) | T3_CAP1_L;
}

/* wait for a STATUS bit; 0 on a timeout */
static unsigned char wait(unsigned char f)
{
  unsigned int n;
  for (n = 0; n < 20000; n++)
    if (T3_STATUS & f)
      return 1;
  return 0;
}

static unsigned char near(unsigned int d, unsigned int want)
{
  return d + 2 >= want && d <= want + 2;
}

void main(void)
{
  unsigned int a, b, c, n;
  unsigned char ok;

  puts("timer 3\n");

  CHECK(1, T3_TOP_L == 0xff && T3_TOP_H == 0xff && T3_PRE == 0 && T3_CTRL == 0 && T3_STATUS == 0);
  T3_PRE = 0x5a;
  T3_CMP1_H = 0xa5;
  T3_IE = 0x1f;
  CHECK(0x11, T3_PRE == 0x5a && T3_CMP1_H == 0xa5 && T3_IE == 0x1f);
  T3_IE = 0;

  T3_CNT_H = 0x12;              /* the high byte held, the low byte loads both */
  T3_CNT_L = 0x34;
  CHECK(2, cnt() == 0x1234);

  /* the plain timer: a tick every 10 clocks, the period 100 ticks */
  T3_PRE = 9;
  T3_TOP_H = 0;
  T3_TOP_L = 99;
  T3_CMP0_H = 0;
  T3_CMP0_L = 50;
  T3_CNT_H = 0;
  T3_CNT_L = 0;
  T3_STATUS = 0x1f;
  T3_CTRL = EN;
  ok = wait(F_OVF);
  T3_STATUS = F_OVF;
  CHECK(3, ok && !(T3_STATUS & F_OVF));
  T3_STATUS = F_CMP0;
  CHECK(4, wait(F_CMP0));

  /* the captures: the counter free-running at the clock */
  T3_CTRL = 0;
  T3_PRE = 0;
  T3_TOP_H = 0xff;
  T3_TOP_L = 0xff;
  T3_CTRL = EN | CAP0_RISE | CAP1_FALL;
  T3_STATUS = 0x1f;
  ok = wait(F_CAP0);
  T3_STATUS = F_CAP0 | F_CAP1;
  ok &= wait(F_CAP0);
  a = cap0();
  T3_STATUS = F_CAP0 | F_CAP1;
  ok &= wait(F_CAP1);
  c = cap1();
  ok &= wait(F_CAP0);
  b = cap0();
  puts("captures ");
  puthex(a); putc(' '); puthex(c); putc(' '); puthex(b); putc('\n');
  CHECK(5, ok && near(b - a, 6000) && near(c - a, 3000));

  /* the interrupt: OVF every 1000 clocks, vector 9 */
  T3_CTRL = 0;
  T3_PRE = 9;
  T3_TOP_H = 0;
  T3_TOP_L = 99;
  T3_STATUS = 0x1f;
  t3_irqs = 0;
  T3_IE = F_OVF;
  T3_CTRL = EN;
  lisa_ei();
  for (n = 0; n < 30000 && t3_irqs < 3; n++)
    ;
  CHECK(6, t3_irqs >= 3);

  T3_IE = 0;                    /* the flag stays, no request */
  a = t3_irqs;
  T3_STATUS = 0x1f;
  ok = wait(F_OVF);
  CHECK(7, ok && t3_irqs == a);
  lisa_di();

  /* PWM0 25%, PWM1 75% of a 100-clock period, left running */
  T3_CTRL = 0;
  T3_PRE = 0;
  T3_TOP_H = 0;
  T3_TOP_L = 99;
  T3_CMP0_H = 0;
  T3_CMP0_L = 25;
  T3_CMP1_H = 0;
  T3_CMP1_L = 75;
  T3_CTRL = EN | PWM0 | PWM1;
  DONE();
  for (;;)
    ;
}
