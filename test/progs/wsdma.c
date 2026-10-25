/* wsdma.c - the WS2812B driver's DMA (RESPIN 35, src/lisa_ws2812.v): frames
 * sent from buffers in the PSRAM through the TTLC's fetch, the TTLC halted
 * (its reset state), the data cache on.  The output flops hold BASE (bytes
 * 0-1, the buffer / 256) and LEN (bytes 2-3, pixels); WS_STAT bit 6 written
 * starts a frame and reads ACTIVE.  The testbench decodes uo[1] and uo[2]
 * (tb.v ws2812_rx) and counts edges on uo[0], uo[5], uo[6].
 *
 *  1 frame A: 7 pixels on uo[1] from 0x4000, written just before START (in
 *    the cache, dirty: the flush), an odd length (half a group at the end);
 *    ACTIVE drops, no underrun
 *  2 an empty frame (LEN 0): ACTIVE drops, nothing sent
 *  3 frame B: 100 pixels on uo[2] from 0x5000 (300 bytes: past 256) while
 *    the core thrashes the data cache (every access a dirty write-back and
 *    a fill), the request (vector 6, FRAME) at its end; no underrun
 *  4 frame C: 3 pixels on uo[1] from 0x4100 with REPEAT, back to back, two
 *    frames seen (FRAME, cleared each time) before REPEAT is cleared; the
 *    frame running then is the last
 *
 * Built with the stack at 0x7fff (the 32K data space). */
#include "harness.h"
#include <tt07.h>

__sfr __at(0x22C) TIDX;
__sfr __at(0x22D) TDATA;
__sfr __at(0x240) WS_CTRL;
__sfr __at(0x241) WS_STAT;

#define EN       0x01
#define PIN(n)   ((n) << 1)
#define IE       0x10
#define DMA      0x20
#define REPEAT   0x40

#define DONE_F   0x08
#define UNDERRUN 0x10
#define ACTIVE   0x40
#define START    0x40
#define FRAME    0x80

#define BUF_A    ((unsigned char *)0x4000)
#define BUF_C    ((unsigned char *)0x4100)
#define BUF_B    ((unsigned char *)0x5000)
#define THRASH   ((volatile unsigned char *)0x6000)

volatile unsigned char ws_irqs;

void ws_isr(void) __interrupt(LISA_INT_TTLC)
{
  ws_irqs++;
  WS_STAT = FRAME;              /* the request is a level: FRAME cleared */
}

/* BASE and LEN into the output flops through the TTLC I/O window */
static void frame(unsigned char base, unsigned int len)
{
  TIDX = 0;
  TDATA = base;
  TDATA = 0;
  TDATA = (unsigned char)len;
  TDATA = (unsigned char)(len >> 8);
}

static unsigned char wait_idle(void)
{
  unsigned long n;
  for (n = 0; n < 400000; n++)
    if (!(WS_STAT & ACTIVE))
      return 1;
  return 0;
}

void main(void)
{
  unsigned char i, ok, st, seen;
  unsigned int k, n;

  puts("wsdma\n");
  WS_STAT = UNDERRUN;

  /* frame A */
  for (i = 0; i < 7; i++) {
    BUF_A[3 * i]     = (unsigned char)(i * 17 + 1);
    BUF_A[3 * i + 1] = (unsigned char)(0x40 ^ i);
    BUF_A[3 * i + 2] = (unsigned char)(0xA0 + i);
  }
  WS_CTRL = EN | PIN(1) | DMA;
  frame(0x40, 7);
  WS_STAT = START;
  ok = (WS_STAT & ACTIVE) != 0;
  ok &= wait_idle();
  st = WS_STAT;
  CHECK(1, ok && !(st & UNDERRUN) && (st & DONE_F));

  /* an empty frame */
  frame(0x40, 0);
  WS_STAT = START;
  ok = wait_idle();
  CHECK(2, ok);

  /* frame B, the cache thrashed meanwhile, the request at its end */
  for (k = 0; k < 300; k += 3) {
    i = (unsigned char)(k / 3);
    BUF_B[k]     = i;
    BUF_B[k + 1] = (unsigned char)(0xFF - i);
    BUF_B[k + 2] = (unsigned char)(i ^ 0x55);
  }
  WS_CTRL = EN | PIN(2) | DMA;
  frame(0x50, 100);
  INT_STATUS = 0xff;
  INT_ENABLE = INT_TTLC;
  ws_irqs = 0;
  lisa_ei();
  WS_STAT = FRAME;                      /* frames A and the empty one ended */
  WS_CTRL = EN | PIN(2) | DMA | IE;
  WS_STAT = START;
  n = 0;
  while (WS_STAT & ACTIVE) {
    THRASH[(n & 31) << 7] += 1;         /* one cache line, 32 tags: a write-back and a fill each */
    n++;
  }
  for (k = 0; k < 1000 && !ws_irqs; k++)
    ;
  lisa_di();
  INT_ENABLE = 0;
  WS_CTRL = EN | PIN(2) | DMA;
  st = WS_STAT;
  CHECK(3, ws_irqs == 1 && !(st & UNDERRUN) && n > 100);

  /* frame C, repeated */
  for (i = 0; i < 3; i++) {
    BUF_C[3 * i]     = (unsigned char)(0x11 * (i + 1));
    BUF_C[3 * i + 1] = 0x22;
    BUF_C[3 * i + 2] = (unsigned char)(0x33 + i);
  }
  WS_CTRL = EN | PIN(1) | DMA | REPEAT;
  frame(0x41, 3);
  WS_STAT = FRAME;
  WS_STAT = START;
  seen = 0;
  for (n = 0; n < 20000 && seen < 2; n++)
    if (WS_STAT & FRAME) {              /* sticky: each repeated frame's end */
      WS_STAT = FRAME;
      seen++;
    }
  WS_CTRL = EN | PIN(1) | DMA;
  ok = seen == 2 && (WS_STAT & ACTIVE);
  ok &= wait_idle();
  st = WS_STAT;
  CHECK(4, ok && !(st & UNDERRUN));

  /* EN stays on (off, the pins are the TTLC's again) */
  DONE();
  for (;;)
    ;
}
