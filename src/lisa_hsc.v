/*
==============================================================================
lisa_hsc.v:  A high-speed / quadrature counter for the LISA core (RESPIN 40).

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


A 16-bit up / down counter on a pair of the chip's inputs (RESPIN 40,
2026-11-14): pulses, pulses with a direction pin, or an incremental
encoder's quadrature at x1 or x4.  Two instances, BASE 0x60 (HSC0) and
0x68 (HSC1); BASE is a multiple of 8.

   +0  CTRL     [1:0] MODE: 0 pulses (A's rising edges count up), 1 pulses
                with direction (B high counts down), 2 quadrature x1 (A's
                rising edge; B's level the direction, B low up), 3 quadrature
                x4 (every edge of A and B).  [3:2] PINS: the input pair, A
                the lower: 0 ui_in[1:0], 1 ui_in[3:2], 2 ui_in[5:4], 3
                ui_in[7:6].  [4] EN.  [5] IE.  [6] CLR (write 1: the count
                <= 0; reads 0).  [7] FILT: an input must hold for four
                clocks to count (a glitch filter).
   +1  STAT     [0] MATCH (sticky: a step landed on CMP), [1] OVF (a step
                up wrapped past 0xFFFF, sticky), [2] UNF (a step down
                wrapped below 0, sticky); a 1 written clears each.  [3] DIR
                (the last step was down), [4] A, [5] B (the inputs as the
                counter sees them: synchronised and, with FILT, filtered),
                [6] GE (count >= CMP, a level), [7] 0.
   +2  CNT_L    read: the count's low byte, and its high byte latched for
                +3; write: the count = {the byte written to +3, this}
   +3  CNT_H    read: the latched high byte; write: held for the next CNT_L
   +4  CMP_L    the compare (reset 0)
   +5  CMP_H
   +6, +7       read 0

irq = IE & (MATCH | OVF | UNF); ge = EN & (count >= CMP), the TTLC's bit.

The selected pair goes through two synchroniser flops, then the filter: a
level is taken when it has been seen on four consecutive clocks (FILT off:
on the first).  A step is decoded the clock the taken level changes.  x4
uses the four-state table {A, B} 00 -> 10 -> 11 -> 01 -> 00 forward and
ignores a step where both inputs changed; x1 and pulses with direction are
the same decode (A's rising edge, B's new level the direction).  A CNT_L
write or CLR in a step's clock takes precedence over the step.  The count
is 3 clocks behind the pin (6 with FILT).
*/

module lisa_hsc
#(
   parameter [6:0] BASE = 7'h60        // 0x60 HSC0, 0x68 HSC1
)
(
   input  wire          clk,
   input  wire          rst_n,
   input  wire [6:0]    d_addr,
   input  wire [7:0]    d_i,
   input  wire          d_periph,
   input  wire          d_we,
   input  wire          d_rd,
   output reg  [7:0]    d_o,
   input  wire [7:0]    ui_in,        // the chip's inputs; CTRL [3:2] picks the pair
   output wire          irq,          // IE & (MATCH | OVF | UNF)
   output wire          ge            // count >= CMP (a level, to the TTLC)
);

   reg   [1:0]    mode;
   reg   [1:0]    pins;
   reg            en;
   reg            ie;
   reg            filt;
   reg            match, ovf, unf;
   reg            dir;
   reg   [15:0]   cnt;
   reg   [7:0]    cnt_hold;            // CNT_H read: latched by the CNT_L read
   reg   [7:0]    cnt_wbuf;            // CNT_H write: held for CNT_L
   reg   [15:0]   cmp;
   reg   [1:0]    sync1, sync2;        // the synchroniser, {B, A}
   reg   [1:0]    fab;                 // the taken (filtered) levels, {B, A}
   reg   [1:0]    fcnt_a, fcnt_b;      // clocks sync2 has differed from fab

   wire           sel;                 // one of our eight addresses
   wire           rsel;                // ... for the read mux: d_addr[3] alone
   wire  [2:0]    a;
   wire           wr, rd;
   wire           load, clr;
   wire  [1:0]    pair;                // the selected inputs, {B, A}
   wire  [1:0]    pass;                // fab takes sync2 this clock
   wire  [1:0]    ab_new;              // fab after this clock
   wire           a_rise;
   reg            q4_up, q4_dn;        // the x4 table's step
   wire           step_up, step_dn, count;
   wire  [15:0]   cnt_step;

   assign sel      = d_addr[6:3] == BASE[6:3];
   assign rsel     = d_addr[3] == BASE[3];      // the read decode: the group d_addr[6:4] is lisa_periph's (t6x4-8)
   assign a        = d_addr[2:0];
   assign wr       = d_periph && d_we && sel;
   assign rd       = d_periph && d_rd && sel;
   assign load     = wr && a == 3'd2;
   assign clr      = wr && a == 3'd0 && d_i[6];

   // the input pair, the filter and the step decode
   assign pair     = pins == 2'd0 ? ui_in[1:0] :
                     pins == 2'd1 ? ui_in[3:2] :
                     pins == 2'd2 ? ui_in[5:4] : ui_in[7:6];
   assign pass     = {sync2[1] != fab[1] && (!filt || fcnt_b == 2'd3),
                      sync2[0] != fab[0] && (!filt || fcnt_a == 2'd3)};
   assign ab_new   = fab ^ pass;
   assign a_rise   = pass[0] && !fab[0];

   // x4: {A old, B old, A new, B new}; forward is 00 -> 10 -> 11 -> 01 -> 00
   always @*
   begin
      case ({fab[0], fab[1], ab_new[0], ab_new[1]})
      4'b00_10, 4'b10_11, 4'b11_01, 4'b01_00: begin q4_up = 1'b1; q4_dn = 1'b0; end
      4'b00_01, 4'b01_11, 4'b11_10, 4'b10_00: begin q4_up = 1'b0; q4_dn = 1'b1; end
      default:                                begin q4_up = 1'b0; q4_dn = 1'b0; end
      endcase
   end

   assign step_up  = en && (mode == 2'd0 ? a_rise :
                            mode == 2'd3 ? q4_up  : a_rise && !ab_new[1]);
   assign step_dn  = en && (mode == 2'd0 ? 1'b0   :
                            mode == 2'd3 ? q4_dn  : a_rise &&  ab_new[1]);
   assign count    = (step_up || step_dn) && !load && !clr;
   assign cnt_step = step_up ? cnt + 16'h1 : cnt - 16'h1;

   assign ge       = en & (cnt >= cmp);      // 0 while disabled: an unconfigured counter reads 0
   assign irq      = ie && (match || ovf || unf);

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         mode     <= 2'h0;
         pins     <= 2'h0;
         en       <= 1'b0;
         ie       <= 1'b0;
         filt     <= 1'b0;
         match    <= 1'b0;
         ovf      <= 1'b0;
         unf      <= 1'b0;
         dir      <= 1'b0;
         cnt      <= 16'h0;
         cnt_hold <= 8'h0;
         cnt_wbuf <= 8'h0;
         cmp      <= 16'h0;
         sync1    <= 2'h0;
         sync2    <= 2'h0;
         fab      <= 2'h0;
         fcnt_a   <= 2'h0;
         fcnt_b   <= 2'h0;
      end
      else
      begin
         sync1  <= pair;
         sync2  <= sync1;
         fab    <= ab_new;
         fcnt_a <= (sync2[0] != fab[0] && !pass[0]) ? fcnt_a + 2'd1 : 2'd0;
         fcnt_b <= (sync2[1] != fab[1] && !pass[1]) ? fcnt_b + 2'd1 : 2'd0;

         if (wr && a == 3'd0)
         begin
            mode <= d_i[1:0];
            pins <= d_i[3:2];
            en   <= d_i[4];
            ie   <= d_i[5];
            filt <= d_i[7];
         end
         if (wr && a == 3'd3) cnt_wbuf  <= d_i;
         if (wr && a == 3'd4) cmp[7:0]  <= d_i;
         if (wr && a == 3'd5) cmp[15:8] <= d_i;
         if (rd && a == 3'd2) cnt_hold  <= cnt[15:8];

         // the count: a load or CLR, else a step
         if (load)
            cnt <= {cnt_wbuf, d_i};
         else if (clr)
            cnt <= 16'h0;
         else if (count)
            cnt <= cnt_step;

         if (count)
            dir <= step_dn;

         // the flags: set by the step, a 1 written clears (a set in the
         // clock of the write wins)
         match <= (match && !(wr && a == 3'd1 && d_i[0])) || (count && cnt_step == cmp);
         ovf   <= (ovf   && !(wr && a == 3'd1 && d_i[1])) || (count && step_up && cnt == 16'hFFFF);
         unf   <= (unf   && !(wr && a == 3'd1 && d_i[2])) || (count && step_dn && cnt == 16'h0);
      end
   end

   always @*
   begin
      case ({rsel, a})
      4'b1_000: d_o = {filt, 1'b0, ie, en, pins, mode};
      4'b1_001: d_o = {1'b0, ge, fab[1], fab[0], dir, unf, ovf, match};
      4'b1_010: d_o = cnt[7:0];
      4'b1_011: d_o = cnt_hold;
      4'b1_100: d_o = cmp[7:0];
      4'b1_101: d_o = cmp[15:8];
      default:  d_o = 8'h0;
      endcase
   end

endmodule
