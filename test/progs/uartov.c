/* uartov.c - the console UART's receive FIFO overrun flag (RESPIN 14, status
 * bit 2).  Prints "ready", then ignores the UART while the testbench sends
 * twelve characters into the 8-byte FIFO, then reports the status, drains
 * the FIFO (eight bytes kept, four lost), reports the status again (the flag
 * clears when the FIFO has been read empty) and echoes from then on.  The
 * report is printed before the drain: a write to the UART must not pop the
 * receive side (RESPIN 23). */
#include "harness.h"

void main(void)
{
  unsigned int i;
  unsigned char st, n;
  char got[9];

  puts("ready\n");
  while (!(UART_STATUS & 1))              /* the first byte of the burst */
    ;
  for (i = 0; i < 20000; i++)             /* the rest arrives: ~1 ms of not reading */
    __asm nop __endasm;
  st = UART_STATUS;
  CHECK(1, (st & 5) == 5);                /* data available, overrun */
  n = 0;
  while (UART_STATUS & 1) {
    if (n < 8)
      got[n] = UART_TX;
    else
      (void)UART_TX;
    n++;
  }
  got[n < 8 ? n : 8] = 0;
  CHECK(2, n == 8 || n == 9);             /* the FIFO held eight; the chip's debug controller one more */
  CHECK(3, (UART_STATUS & 4) == 0);       /* read empty: the flag is gone */
  CHECK(4, got[0] == '0' && got[7] == '7');
  puts("got ");
  puts(got);
  putc('\n');
  DONE();
  for (;;) {                              /* then the echo, as hello */
    while (!(UART_STATUS & 1))
      ;
    putc(UART_TX);
  }
}
