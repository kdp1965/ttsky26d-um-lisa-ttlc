/* ws2812.c - the WS2812B driver (RESPIN 33, src/lisa_ws2812.v): the pixels in
 * the TTLC's output flops (two halves of G, R, B through the TTLC I/O
 * window, TIDX / TDATA), the line on one of mux 3's TTLC pins, the TTLC
 * itself halted (its reset state).  The testbench decodes uo[1] and uo[2]
 * (tb.v ws2812_rx: pixels, a hash of them, frames, malformed pulses) and
 * counts rising edges on uo[0], uo[5], uo[6], which must stay low.
 *
 *  1 the registers' reset values (the 50 MHz timing)
 *  2 frame 1: 8 pixels on uo[1] through the ping-pong halves, DONE after
 *    it, no underrun
 *  3 frame 2: 3 pixels on uo[2]
 *  4 the interrupt: with IE a free half requests source 5 (vector 6); the
 *    handler drops IE
 *  5 frame 3 on uo[1]: a pixel, then the second only after the line has
 *    gone low - UNDERRUN; a 1 written clears it
 *
 * The pixels go in through ws_put, a 16-instruction assembly loader: in C
 * a pixel took 1300-2000 clocks on the Arty (instruction fetch from its
 * flash Pmod), as long as sending one, so the line went low between pixels
 * (UNDERRUN).  The bit is 75 clocks (WS_TBIT 74, 1.5 us at 50 MHz: within
 * the WS2812B's 1.25 +- 0.6 us), a pixel 1800 clocks. */
#include "harness.h"
#include <tt07.h>

__sfr __at(0x22C) TIDX;
__sfr __at(0x22D) TDATA;
__sfr __at(0x240) WS_CTRL;
__sfr __at(0x241) WS_STAT;
__sfr __at(0x242) WS_T0H;
__sfr __at(0x243) WS_T1H;
__sfr __at(0x244) WS_TBIT;
__sfr __at(0x245) WS_TRST;

#define EN       0x01
#define PIN(n)   ((n) << 1)
#define IE       0x10

#define FULL_A   0x01
#define FULL_B   0x02
#define BUSY     0x04
#define DONE_F   0x08
#define UNDERRUN 0x10

volatile unsigned char ws_irqs;

void ws_isr(void) __interrupt(LISA_INT_TTLC)
{
  ws_irqs++;
  WS_CTRL = EN | PIN(1);        /* drop IE: the request is a level */
}

unsigned char ws_half;          /* the half filled next: 0 A, 1 B */

/* ws_put(g, r, b): a pixel into the next half once it is free.  g comes
   in A, r and b at 0(sp) / 1(sp) (sdcc's convention); after the push of g
   they are g 0(sp), r 1(sp), b 2(sp).  A leaf: RA untouched, ret. */
static void ws_put(unsigned char g, unsigned char r, unsigned char b) __naked
{
  (void) g; (void) r; (void) b;
  __asm
    push  a
    lda   _ws_half
    bnz   00002$
00001$:
    lda   _WS_STAT              ; half A: wait for FULL_A clear
    andi  #0x01
    bnz   00001$
    ldi   #0x00
    sta   _TIDX
    ldax  0(sp)
    sta   _TDATA
    ldax  1(sp)
    sta   _TDATA
    ldax  2(sp)
    sta   _TDATA
    ldi   #0x01
    sta   _WS_STAT              ; FULL_A
    sta   _ws_half              ; B next
    ads   #1
    ret
00002$:
    lda   _WS_STAT              ; half B: wait for FULL_B clear
    andi  #0x02
    bnz   00002$
    ldi   #0x03
    sta   _TIDX
    ldax  0(sp)
    sta   _TDATA
    ldax  1(sp)
    sta   _TDATA
    ldax  2(sp)
    sta   _TDATA
    ldi   #0x02
    sta   _WS_STAT              ; FULL_B
    ldi   #0x00
    sta   _ws_half              ; A next
    ads   #1
    ret
  __endasm;
}

/* a pixel, and 1 (the C version's timeout is gone: ws_put waits) */
static unsigned char put(unsigned char g, unsigned char r, unsigned char b)
{
  ws_put(g, r, b);
  return 1;
}

static unsigned char wait_done(void)
{
  unsigned int n;
  for (n = 0; n < 30000; n++)
    if (WS_STAT & DONE_F)
      return 1;
  return 0;
}

void main(void)
{
  unsigned char i, ok, st;
  unsigned int n;

  puts("ws2812\n");

  CHECK(1, WS_CTRL == 0 && WS_T0H == 20 && WS_T1H == 40 && WS_TBIT == 62 && WS_TRST == 219 &&
           (WS_STAT & (DONE_F | FULL_A | FULL_B | BUSY)) == DONE_F);

  WS_TBIT = 74;                 /* a 1.5 us bit: 1800 clocks a pixel */

  /* frame 1: 8 pixels on uo[1] */
  WS_CTRL = EN | PIN(1);
  ws_half = 0;
  ok = 1;
  for (i = 0; i < 8; i++)
    ok &= put((unsigned char)((i << 4) | 1), (unsigned char)(0x80 ^ i), (unsigned char)(0xC3 + i));
  ok &= wait_done();
  st = WS_STAT;
  CHECK(2, ok && !(st & UNDERRUN) && !(st & (FULL_A | FULL_B)));

  /* frame 2: 3 pixels on uo[2] - the pin switched with EN kept on (off,
     the pins are the TTLC's again and show its data: a glitch on the
     string); every frame starts at half A */
  WS_CTRL = EN | PIN(2);
  ws_half = 0;
  ok = 1;
  for (i = 0; i < 3; i++)
    ok &= put((unsigned char)(0x10 + i), (unsigned char)(0x20 + i), (unsigned char)(0x30 + i));
  ok &= wait_done();
  CHECK(3, ok && !(WS_STAT & UNDERRUN));

  /* the interrupt: both halves free, IE set */
  WS_CTRL = EN | PIN(1);
  INT_STATUS = 0xff;
  INT_ENABLE = INT_TTLC;
  ws_irqs = 0;
  lisa_ei();
  WS_CTRL = EN | PIN(1) | IE;
  for (n = 0; n < 1000 && !ws_irqs; n++)
    ;
  lisa_di();
  INT_ENABLE = 0;
  CHECK(4, ws_irqs == 1 && !(WS_CTRL & IE));

  /* frame 3: a late second pixel */
  WS_TRST = 255;                /* the longest reset: the gap stays inside it */
  ws_half = 0;
  ok = put(0x5A, 0xA5, 0x0F);
  for (n = 0; n < 20000 && !(WS_STAT & BUSY); n++)
    ;
  for (n = 0; n < 20000 && (WS_STAT & BUSY); n++)
    ;
  ok &= put(0xF0, 0x3C, 0xC3);
  ok &= wait_done();
  st = WS_STAT;
  WS_STAT = UNDERRUN;
  CHECK(5, ok && (st & UNDERRUN) && !(WS_STAT & UNDERRUN));

  /* EN stays on: turned off, the pins go back to the TTLC (its latch,
     uo[5], idles high) */
  DONE();
  for (;;)
    ;
}
