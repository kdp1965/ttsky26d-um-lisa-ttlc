/* spi.c - the SPI master (RESPIN 29, src/lisa_spi.v) against the
 * testbench's two devices (tb.v spi_dev): device 0 on CS0 (CPHA 0) answers
 * each byte with the complement of the one before, device 1 on CS1 (CPHA 1)
 * with it plus one, the first byte of a select with 0x96 / 0x3c.  Every
 * clock divider in DIVS and both clock polarities, the registers' readback,
 * DONE and its interrupt request (INT_STATUS bit 7).
 *
 * PORT A bit 0 high: the TTLC's pins (mux mode 3), the TTLC running its
 * loopback - every transaction claims the pins first, waits for the grant
 * and releases them after; the testbench checks the TTLC's outputs and that
 * no scan ran inside a transaction.  The TTLC asking to scan while the pins
 * are held (STATUS bit 3) must be seen: the interlock was exercised. */
#include "harness.h"

__sfr __at(0x200) PORTA;
__sfr __at(0x20F) INT_STATUS;
__sfr __at(0x228) SPI_DATA;
__sfr __at(0x229) SPI_CTRL;
__sfr __at(0x22A) SPI_DIV;
__sfr __at(0x22B) SPI_STATUS;

#define CS0     0x01
#define CS1     0x02
#define CPOL    0x04
#define CPHA    0x08
#define CLAIM   0x10
#define MISO2   0x40          /* MISO from ui_in[2] */
#define IE      0x80

#define ST_BUSY   0x01
#define ST_DONE   0x02
#define ST_OWNED  0x04
#define ST_WAIT   0x08

static unsigned char mode3;
static unsigned char waits;    /* transactions that saw the TTLC waiting */

static unsigned char xfer(unsigned char b)
{
  SPI_DATA = b;
  while (SPI_STATUS & ST_BUSY)
    ;
  return SPI_DATA;
}

/* select: on the TTLC's pins claim them first (the selects deasserted),
 * then assert the select */
static void sel(unsigned char ctrl)
{
  if (mode3) {
    SPI_CTRL = (ctrl & ~(CS0 | CS1)) | CLAIM;
    while (!(SPI_STATUS & ST_OWNED))
      ;
    ctrl |= CLAIM;
  }
  SPI_CTRL = ctrl;
}

static void desel(unsigned char ctrl)
{
  if (mode3 && (SPI_STATUS & ST_WAIT))
    waits++;
  SPI_CTRL = ctrl & ~(CS0 | CS1);
  if (mode3)
    SPI_CTRL = ctrl & ~(CS0 | CS1 | CLAIM);
}

/* three bytes to device 0 and three to device 1: 0 when every answer is right */
static unsigned char pair(unsigned char cpol)
{
  unsigned char bad = 0;

  sel(MISO2 | cpol | CS0);
  if (xfer(0x5a) != 0x96) bad |= 1;
  if (xfer(0x13) != 0xa5) bad |= 2;
  if (xfer(0x00) != 0xec) bad |= 4;
  desel(MISO2 | cpol | CS0 | (mode3 ? CLAIM : 0));

  sel(MISO2 | CPHA | cpol | CS1);
  if (xfer(0x10) != 0x3c) bad |= 8;
  if (xfer(0x20) != 0x11) bad |= 16;
  if (xfer(0x30) != 0x21) bad |= 32;
  desel(MISO2 | CPHA | cpol | CS1 | (mode3 ? CLAIM : 0));
  return bad;
}

static const unsigned char DIVS[3] = { 0, 1, 5 };

void main(void)
{
  unsigned char i, d, bad, st;

  mode3 = PORTA & 1;
  puts(mode3 ? "spi on the TTLC pins\n" : "spi on the mux-2 pins\n");

  SPI_DIV = 5;
  SPI_CTRL = MISO2 | CPHA;
  CHECK(1, SPI_DIV == 5 && SPI_CTRL == (MISO2 | CPHA) && (SPI_STATUS & 0x0f) == 0);
  SPI_CTRL = 0;

  /* every divider, both polarities */
  for (d = 0; d < 3; d++) {
    SPI_DIV = DIVS[d];
    bad = pair(0) | pair(CPOL);
    CHECK(0x10 + d, bad == 0);
    if (bad)
      puthex(bad), putc('\n');
  }

  /* DONE and the interrupt request: set when the byte is in, both cleared
   * by reading DATA */
  sel(IE | MISO2 | CS0);
  SPI_DATA = 0x77;
  while (SPI_STATUS & ST_BUSY)
    ;
  st = SPI_STATUS;
  i = INT_STATUS;
  d = SPI_DATA;
  CHECK(2, (st & ST_DONE) && (i & 0x80) && d == 0x96);
  CHECK(3, !(SPI_STATUS & ST_DONE) && !(INT_STATUS & 0x80));
  desel(IE | MISO2 | CS0 | (mode3 ? CLAIM : 0));
  SPI_CTRL = 0;

  if (mode3) {
    /* many transactions against the running TTLC */
    SPI_DIV = 5;
    bad = 0;
    for (i = 0; i < 24; i++)
      bad |= pair(i & 1 ? CPOL : 0);
    CHECK(4, bad == 0);
    CHECK(5, waits != 0);
    CHECK(6, !(SPI_STATUS & ST_OWNED));
    puts("waits ");
    puthex(waits);
    putc('\n');
  }
  DONE();
  for (;;)
    ;
}
