/* ttlcio.c - the TTLC's I/O from the LISA core (RESPIN 30, src/lisa_ttlcio.v):
 * the 139-bit I/O vector as 18 bytes through TIDX / TDATA, scans started
 * with TCTRL, against the testbench's 74HC595 / 74HC165 chains (mux mode 3).
 * The testbench puts INPUTS on the 165 chains before the run and checks the
 * 595 chains after it.
 *
 * PORT A bit 0 low: the ICU is halted (the reset state) and the chains are
 * the core's: the index, its auto-increment and wrap, byte 17's constants,
 * port_in (port E) at byte 16, outputs and storage written and read back,
 * the storage's low byte on port D, the inputs not writable, a scan by
 * START (BUSY, DONE, DONE cleared by the read), the inputs it captured, and
 * a second set of outputs left on the chains (OUT2) for the testbench.
 *
 * PORT A bit 0 high: the ICU runs its loopback (inputs to outputs).  The
 * core watches without stopping it (DONE per scan, the inputs and the
 * outputs it copied), then takes the SPI master's claim, waits for the ICU
 * to hold at its next scan (TTLC_WAIT), writes OUT1, runs a scan of its own
 * (allowed while it holds the claim), finds OUT1 still in the outputs (the
 * ICU waits), releases, and sees the loopback put INPUTS back. */
#include "harness.h"

__sfr __at(0x200) PORTA;
__sfr __at(0x204) PORTD;
__sfr __at(0x205) PORTE;
__sfr __at(0x229) SPI_CTRL;
__sfr __at(0x22B) SPI_STATUS;
__sfr __at(0x22C) TIDX;
__sfr __at(0x22D) TDATA;
__sfr __at(0x22E) TCTRL;

#define ST_BUSY   0x01
#define ST_DONE   0x02
#define ST_PEND   0x04
#define ST_WAIT   0x08
#define ST_OWNED  0x10

#define CLAIM     0x10
#define SPI_OWNED 0x04

static const unsigned char INPUTS[6] = { 0xab, 0x89, 0x67, 0x45, 0x23, 0x01 };   /* 0x0123456789ab */
static const unsigned char OUT1[6]   = { 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
static const unsigned char OUT2[6]   = { 0xc3, 0x3c, 0xa5, 0x5a, 0x0f, 0xf0 };   /* 0xf00f5aa53cc3 */

static unsigned char buf[6];

static void put2(unsigned char v)
{
  const char *h = "0123456789abcdef";
  putc(h[v >> 4]);
  putc(h[v & 15]);
}

static void wr6(unsigned char first, const unsigned char *p)
{
  unsigned char i;
  TIDX = first;
  for (i = 0; i < 6; i++)
    TDATA = p[i];
}

static void rd6(unsigned char first)
{
  unsigned char i;
  TIDX = first;
  for (i = 0; i < 6; i++)
    buf[i] = TDATA;
}

static unsigned char same6(const unsigned char *p)
{
  unsigned char i;
  for (i = 0; i < 6; i++)
    if (buf[i] != p[i])
      return 0;
  return 1;
}

static void show6(const char *what)
{
  unsigned char i;
  puts(what);
  for (i = 6; i > 0; i--)
    put2(buf[i - 1]);
  putc('\n');
}

/* the next DONE (a scan ended); 0 on a timeout */
static unsigned char wait_done(void)
{
  unsigned int n;
  for (n = 0; n < 20000; n++)
    if (TCTRL & ST_DONE)
      return 1;
  return 0;
}

/* START a scan and wait for its end (START clears DONE first) */
static unsigned char scan(void)
{
  TCTRL = 1;
  return wait_done();
}

void main(void)
{
  unsigned char a, b, c, st;
  unsigned int n;

  if (!(PORTA & 1))
    {
      puts("ttlc i/o, the icu halted\n");

      TIDX = 3;
      a = TIDX;
      (void) TDATA;
      b = TIDX;
      TIDX = 17;
      (void) TDATA;
      c = TIDX;
      TIDX = 23;
      (void) TDATA;
      st = TIDX;
      CHECK(1, a == 3 && b == 4 && c == 18 && st == 0);   /* 24 bytes since RESPIN 31: 23 wraps */

      TIDX = 17;
      a = TDATA;                               /* {.., 1, 0, RR} */
      PORTE = 0x5a;
      TIDX = 16;
      b = TDATA;                               /* port_in */
      CHECK(2, (a & 0xfe) == 0x04 && b == 0x5a);

      wr6(0, OUT1);
      rd6(0);
      CHECK(3, same6(OUT1));

      wr6(12, OUT2);                           /* the storage: bytes 12-15 (the last two writes go to 16, 17: ignored) */
      TIDX = 12;
      a = TDATA; b = TDATA; c = TDATA;
      st = TDATA;
      CHECK(4, a == OUT2[0] && b == OUT2[1] && c == OUT2[2] && st == OUT2[3] && PORTD == OUT2[0]);
      TIDX = 16;
      CHECK(5, TDATA == 0x5a);                 /* port_in untouched by the write past 15 */

      wr6(18, OUT1);                           /* 18-19 ignore writes, 20-23 the storage's bits 32-63 */
      TIDX = 18;
      a = TDATA; b = TDATA;
      rd6(18);
      CHECK(0x0d, a == 0 && b == 0 && buf[0] == 0 && buf[1] == 0 &&
            buf[2] == OUT1[2] && buf[3] == OUT1[3] && buf[4] == OUT1[4] && buf[5] == OUT1[5]);
      TIDX = 12;
      CHECK(0x0e, TDATA == OUT2[0]);           /* the low storage untouched by the high */

      TIDX = 6;
      a = TDATA;
      TIDX = 6;
      TDATA = ~a;                              /* the inputs cannot be written */
      TIDX = 6;
      CHECK(6, TDATA == a);

      st = TCTRL;
      CHECK(7, !(st & (ST_BUSY | ST_PEND | ST_OWNED)));
      CHECK(8, scan());
      CHECK(9, !(TCTRL & ST_DONE));            /* the read cleared it */
      rd6(6);
      show6("inputs ");
      CHECK(0x0a, same6(INPUTS));

      wr6(0, OUT2);                            /* left on the chains for the testbench */
      CHECK(0x0b, scan());
      rd6(0);
      CHECK(0x0c, same6(OUT2));
    }
  else
    {
      puts("ttlc i/o, the icu running\n");

      (void) TCTRL;                            /* watch two scans of the ICU's */
      CHECK(0x10, wait_done() && wait_done());
      rd6(6);
      show6("inputs ");
      CHECK(0x11, same6(INPUTS));
      rd6(0);
      show6("outputs ");
      CHECK(0x12, same6(INPUTS));              /* the loopback's copy */

      SPI_CTRL = CLAIM;                        /* hold the ICU at its next scan */
      for (n = 0; n < 20000 && !(SPI_STATUS & SPI_OWNED); n++)
        ;
      st = 0;
      for (n = 0; n < 20000; n++)
        if ((st = TCTRL) & ST_WAIT)
          break;
      CHECK(0x13, (st & (ST_OWNED | ST_WAIT)) == (ST_OWNED | ST_WAIT));

      wr6(0, OUT1);
      CHECK(0x14, scan());                     /* the core's scan while it holds the claim */
      rd6(0);
      CHECK(0x15, same6(OUT1));                /* the ICU did not run */
      rd6(6);
      CHECK(0x16, same6(INPUTS));

      SPI_CTRL = 0;                            /* release: the ICU's scan, then its loop */
      (void) TCTRL;
      CHECK(0x17, wait_done() && wait_done() && wait_done());
      rd6(0);
      show6("outputs ");
      CHECK(0x18, same6(INPUTS));
    }
  DONE();
  for (;;)
    ;
}
