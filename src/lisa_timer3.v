/*
==============================================================================
lisa_timer3.v:  Timer 3 for the LISA core - PWM and input capture (RESPIN 32).

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


A 16-bit timer with a prescaler, two compare outputs (PWM) and two input
captures (Ken, 2026-10-24).  The counter runs 0..TOP and wraps; with the
PWM outputs off it is a plain timer with an overflow interrupt.

   0x30  PRE      the counter ticks every PRE + 1 clocks (reset 0)
   0x31  TOP_L    the period: the counter runs 0..TOP (reset 0xFFFF)
   0x32  TOP_H
   0x33  CNT_L    read: the count's low byte, and its high byte latched for
                  0x34; write: the count = {the byte written to 0x34, this}
   0x34  CNT_H    read: the latched high byte; write: held for the next CNT_L
   0x35  CMP0_L   PWM0 is high while CNT < CMP0 (CMP0 0: low, above TOP:
   0x36  CMP0_H   high); CMP0 flags when the count reaches it
   0x37  CMP1_L   the same for PWM1
   0x38  CMP1_H
   0x39  CAP0_L   CNT at the last selected edge of ui_in[4] (read only)
   0x3A  CAP0_H
   0x3B  CAP1_L   CNT at the last selected edge of ui_in[5] (read only)
   0x3C  CAP1_H
   0x3D  CTRL     [0] EN, [1] PWM0 out (uo[1] in mux 2), [2] PWM1 out
                  (uo[2]), [5:4] CAP0 edge, [7:6] CAP1 edge: 0 off, 1
                  rising, 2 falling, 3 both
   0x3E  IE       [0] OVF, [1] CMP0, [2] CMP1, [3] CAP0, [4] CAP1
   0x3F  STATUS   the same events, set when they happen; a 1 written clears

Any enabled event in STATUS is the core's interrupt source 8 (vector 9).
The capture inputs are synchronised (two flops); a capture takes the count
of the clock the synchronised edge is seen.  The PWM outputs are flops.
*/

module lisa_timer3
(
   input  wire          clk,
   input  wire          rst_n,

   input  wire [6:0]    d_addr,
   input  wire [7:0]    d_i,
   input  wire          d_periph,
   input  wire          d_we,
   input  wire          d_rd,
   output reg  [7:0]    d_o,

   input  wire [1:0]    cap_in,        // ui_in[5:4]
   output reg  [1:0]    pwm,
   output wire [1:0]    pwm_oe,        // the PWM outputs enabled (lisa_io_mux.v)
   output wire          irq
);

   reg   [7:0]    pre;
   reg   [7:0]    pcnt;
   reg   [15:0]   top;
   reg   [15:0]   cnt;
   reg   [7:0]    cnt_hold;            // CNT_H read: latched by the CNT_L read
   reg   [7:0]    cnt_wbuf;            // CNT_H write: held for CNT_L
   reg   [15:0]   cmp0, cmp1;
   reg   [15:0]   cap0, cap1;
   reg   [7:0]    ctrl;
   reg   [4:0]    ie;
   reg   [4:0]    status;
   reg   [1:0]    sync1, sync2, last;
   wire           wr;
   wire           tick;
   wire  [15:0]   cnt_next;
   wire  [1:0]    rise, fall, edge_hit;

   assign wr       = d_periph && d_we;
   assign tick     = ctrl[0] && pcnt == pre;
   assign cnt_next = cnt == top ? 16'h0 : cnt + 16'h1;
   assign rise     = sync2 & ~last;
   assign fall     = ~sync2 & last;
   assign edge_hit = {(rise[1] & ctrl[6]) | (fall[1] & ctrl[7]),
                      (rise[0] & ctrl[4]) | (fall[0] & ctrl[5])};
   assign pwm_oe   = ctrl[2:1];
   assign irq      = |(status & ie);

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         pre      <= 8'h0;
         pcnt     <= 8'h0;
         top      <= 16'hFFFF;
         cnt      <= 16'h0;
         cnt_hold <= 8'h0;
         cnt_wbuf <= 8'h0;
         cmp0     <= 16'h0;
         cmp1     <= 16'h0;
         cap0     <= 16'h0;
         cap1     <= 16'h0;
         ctrl     <= 8'h0;
         ie       <= 5'h0;
         status   <= 5'h0;
         sync1    <= 2'h0;
         sync2    <= 2'h0;
         last     <= 2'h0;
         pwm      <= 2'h0;
      end
      else
      begin
         sync1 <= cap_in;
         sync2 <= sync1;
         last  <= sync2;

         if (wr && d_addr == 7'h30) pre        <= d_i;
         if (wr && d_addr == 7'h31) top[7:0]   <= d_i;
         if (wr && d_addr == 7'h32) top[15:8]  <= d_i;
         if (wr && d_addr == 7'h34) cnt_wbuf   <= d_i;
         if (wr && d_addr == 7'h35) cmp0[7:0]  <= d_i;
         if (wr && d_addr == 7'h36) cmp0[15:8] <= d_i;
         if (wr && d_addr == 7'h37) cmp1[7:0]  <= d_i;
         if (wr && d_addr == 7'h38) cmp1[15:8] <= d_i;
         if (wr && d_addr == 7'h3D) ctrl       <= d_i;
         if (wr && d_addr == 7'h3E) ie         <= d_i[4:0];
         if (d_periph && d_rd && d_addr == 7'h33)
            cnt_hold <= cnt[15:8];

         // the prescaler and the counter; a CNT_L write restarts the prescale
         if (wr && d_addr == 7'h33)
         begin
            cnt  <= {cnt_wbuf, d_i};
            pcnt <= 8'h0;
         end
         else if (ctrl[0])
         begin
            pcnt <= tick ? 8'h0 : pcnt + 8'h1;
            if (tick)
               cnt <= cnt_next;
         end

         if (edge_hit[0]) cap0 <= cnt;
         if (edge_hit[1]) cap1 <= cnt;

         // the events: set when they happen, a 1 written clears (an event
         // in the clock of the write wins)
         status <= (status & ~((wr && d_addr == 7'h3F) ? d_i[4:0] : 5'h0)) |
                   {edge_hit[1], edge_hit[0],
                    tick && cnt_next == cmp1, tick && cnt_next == cmp0,
                    tick && cnt == top};

         pwm <= {ctrl[0] && cnt < cmp1, ctrl[0] && cnt < cmp0};
      end
   end

   always @*
   begin
      case (d_addr)
      7'h30:   d_o = pre;
      7'h31:   d_o = top[7:0];
      7'h32:   d_o = top[15:8];
      7'h33:   d_o = cnt[7:0];
      7'h34:   d_o = cnt_hold;
      7'h35:   d_o = cmp0[7:0];
      7'h36:   d_o = cmp0[15:8];
      7'h37:   d_o = cmp1[7:0];
      7'h38:   d_o = cmp1[15:8];
      7'h39:   d_o = cap0[7:0];
      7'h3A:   d_o = cap0[15:8];
      7'h3B:   d_o = cap1[7:0];
      7'h3C:   d_o = cap1[15:8];
      7'h3D:   d_o = ctrl;
      7'h3E:   d_o = {3'h0, ie};
      7'h3F:   d_o = {3'h0, status};
      default: d_o = 8'h0;
      endcase
   end

endmodule
