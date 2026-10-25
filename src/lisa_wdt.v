/*
==============================================================================
lisa_wdt.v:  A watchdog timer for the LISA core (RESPIN 36).

Copyright 2026 by Ken Pettit <pettitkd@gmail.com>

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.

A watchdog: once enabled it must be kicked within the timeout, or it resets
the LISA core and the peripherals (lisa_periph.v; not itself, the debug
registers or the QSPI configuration, so the program restarts from address
0 the way the debugger's reset restarts it).  The timeout is (TIMEOUT + 1)
x 2^(16 + SCALE) clocks: at 50 MHz 1.3 ms to 43 s.  After it fires EN is
clear and WDRST set, so a program can tell a watchdog restart from a
power-on one and choose to enable it again.

   0x4C  WDT_CTRL     [0] EN, [3:1] SCALE (a write restarts the count)
   0x4D  WDT_KICK     write 0xA5: the count restarts (other values are
                      ignored); read: the ticks counted so far
   0x4E  WDT_TIMEOUT  the timeout in ticks of 2^(16 + SCALE) clocks, less
                      one (reset 255)
   0x4F  WDT_STAT     [0] WDRST: the last reset was the watchdog's (a 1
                      written clears it)
*/

module lisa_wdt
(
   input  wire          clk,
   input  wire          rst_n,         // power-on: not the watchdog's own

   input  wire [6:0]    d_addr,
   input  wire [7:0]    d_i,
   input  wire          d_periph,
   input  wire          d_we,
   output reg  [7:0]    d_o,

   output wire          wdt_reset      // resets the core and the peripherals
);

   reg            en;
   reg   [2:0]    scale;
   reg   [7:0]    timeout;
   reg   [7:0]    ticks;
   reg   [22:0]   pre;                 // clocks within a tick
   reg            wdrst;
   reg   [2:0]    rst_cnt;             // the reset pulse: 7 clocks
   wire           wr = d_periph && d_we;
   wire  [22:0]   tick_mask = ~(23'h7fffff << (5'd16 + {2'b00, scale}));
   wire           tick = (pre & tick_mask) == tick_mask;
   wire           restart = (wr && d_addr == 7'h4C) || (wr && d_addr == 7'h4D && d_i == 8'hA5);

   assign wdt_reset = rst_cnt != 3'h0;

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         en      <= 1'b0;
         scale   <= 3'h0;
         timeout <= 8'hff;
         ticks   <= 8'h0;
         pre     <= 23'h0;
         wdrst   <= 1'b0;
         rst_cnt <= 3'h0;
      end
      else
      begin
         if (wr && d_addr == 7'h4C)
         begin
            en    <= d_i[0];
            scale <= d_i[3:1];
         end
         if (wr && d_addr == 7'h4E)
            timeout <= d_i;
         if (wr && d_addr == 7'h4F && d_i[0])
            wdrst <= 1'b0;

         if (rst_cnt != 3'h0)
            rst_cnt <= rst_cnt - 3'h1;

         if (!en || restart)
         begin
            pre   <= 23'h0;
            ticks <= 8'h0;
         end
         else if (tick)
         begin
            pre <= 23'h0;
            if (ticks == timeout)
            begin
               // expired: reset the core and the peripherals, and stop
               en      <= 1'b0;
               wdrst   <= 1'b1;
               ticks   <= 8'h0;
               rst_cnt <= 3'h7;
            end
            else
               ticks <= ticks + 8'h1;
         end
         else
            pre <= pre + 23'h1;
      end
   end

   always @*
   begin
      case (d_addr)
      7'h4C:   d_o = {4'h0, scale, en};
      7'h4D:   d_o = ticks;
      7'h4E:   d_o = timeout;
      7'h4F:   d_o = {7'h0, wdrst};
      default: d_o = 8'h0;
      endcase
   end

endmodule
