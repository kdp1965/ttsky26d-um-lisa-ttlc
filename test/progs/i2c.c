/* i2c.c - the I2C master (lisa_i2c.v) in io mux mode 3: the chip selects
 * through the custom Pmod's CE latch (tb.v's 7475, the data cache on through
 * it) and SCL / SDA on uio[4] / uio[5] (0x1C = 0x00FA), 400 kHz (prescale
 * 24 at 50 MHz).  tb.v's slave at 0x3C (an SSD1309 OLED's address) takes
 * the bytes; test.py checks them.
 *
 *  1 a probe of 0x3D: not acknowledged, then a stop
 *  2 0x3C: a command transaction (control byte 0x00, the SSD1309's init)
 *  3 0x3C: a data transaction (control 0x40, 16 bytes)
 *
 * Built with the stack at 0x7fff (the 32K data space). */
#include "harness.h"
#include <tt07.h>

#define STA   0x80
#define STO   0x40
#define RD    0x20
#define WR    0x10
#define TIP   0x02
#define RXACK 0x80

static const unsigned char init[] = {
  0xAE, 0xD5, 0xA0, 0xA8, 0x3F, 0xD3, 0x00, 0x40, 0xA1, 0xC8, 0xDA, 0x12,
  0x81, 0x6F, 0xD9, 0xD3, 0xDB, 0x34, 0xA4, 0xA6, 0x20, 0x00, 0xAF
};

/* a byte with cmd's start / stop; 1 if it was acknowledged */
static unsigned char i2c_byte(unsigned char b, unsigned char cmd)
{
  I2C_TX_DATA = b;
  I2C_CMD = cmd | WR;
  while (I2C_STATUS & TIP)
    ;
  return !(I2C_STATUS & RXACK);
}

void main(void)
{
  unsigned char i, ok;

  puts("i2c\n");
  I2C_CTRL = 0;
  I2C_PRESCALE_LO = 24;
  I2C_PRESCALE_HI = 0;
  I2C_CTRL = 1;

  ok = !i2c_byte(0x3D << 1, STA | STO);
  CHECK(1, ok);

  ok = i2c_byte(0x3C << 1, STA);
  ok &= i2c_byte(0x00, 0);
  for (i = 0; i < sizeof init; i++)
    ok &= i2c_byte(init[i], i == sizeof init - 1 ? STO : 0);
  CHECK(2, ok);

  ok = i2c_byte(0x3C << 1, STA);
  ok &= i2c_byte(0x40, 0);
  for (i = 0; i < 16; i++)
    ok &= i2c_byte((unsigned char)(i * 37 + 5), i == 15 ? STO : 0);
  CHECK(3, ok);

  DONE();
  for (;;)
    ;
}
