/*
==============================================================================
lisa_splim.v:  The stack pointer limit fault (RESPIN 40).

The stack grows down from 0x7FFFFF; a stack overflow walks into the data
below it and is the classic silent failure of an 8-bit RTOS port.  The
core's SP (sp_o) is compared with a 23-bit limit every clock; SP below the
limit while enabled is a fault.

   0x7A  LIM_L   the limit's bits 7:0 (r/w)
   0x7B  LIM_M   bits 15:8
   0x7C  LIM_H   bits 22:16 (bit 7 reads 0)
   0x7D  CTRL    [0] EN, [1] RST_ACT (0: interrupt, 1: reset the core and the
                 peripherals like the watchdog), [2] IE, [3] FAULT (sticky: a
                 1 written clears it); bits 7:4 read 0

A fault sets FAULT.  With RST_ACT it pulses rst_o for one clock (ORed into
the watchdog's reset by the top level) and clears EN, so the restarted
program is not reset again before it has looked; the limit, RST_ACT and
FAULT keep their values through that reset (they are on rst_por_n), so it
can tell a stack fault from a power-on.  Without RST_ACT the request irq =
IE & FAULT is interrupt source 10 (vector 11) until FAULT is cleared.

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
==============================================================================
*/

module lisa_splim
(
   input  wire          clk,
   input  wire          rst_por_n,     // the chip's reset only: the registers survive the fault reset
   input  wire [6:0]    d_addr,
   input  wire [7:0]    d_i,
   input  wire          d_periph,
   input  wire          d_we,
   input  wire          d_rd,
   output reg  [7:0]    d_o,
   input  wire [22:0]   sp,            // the core's stack pointer (lisa_core.v sp_o)
   output wire          irq,           // IE & FAULT (interrupt source 10)
   output reg           rst_o          // one clock: reset the core and the peripherals
);

   reg  [22:0]   lim;
   reg           en;
   reg           rst_act;
   reg           ie;
   reg           fault;

   wire          wr    = d_periph & d_we;
   wire          below = en & (sp < lim);

   assign irq = ie & fault;

   always @(posedge clk)
   begin
      if (~rst_por_n)
      begin
         lim     <= 23'h0;
         en      <= 1'b0;
         rst_act <= 1'b0;
         ie      <= 1'b0;
         fault   <= 1'b0;
         rst_o   <= 1'b0;
      end
      else
      begin
         rst_o <= 1'b0;
         if (below)
         begin
            fault <= 1'b1;
            if (rst_act)
            begin
               rst_o <= 1'b1;
               en    <= 1'b0;
            end
         end
         // the write last, so that a handler's one write (FAULT cleared, EN
         // off) wins while SP is still below the limit; with EN left on the
         // level sets FAULT again the next clock
         if (wr && d_addr == 7'h7A) lim[7:0]   <= d_i;
         if (wr && d_addr == 7'h7B) lim[15:8]  <= d_i;
         if (wr && d_addr == 7'h7C) lim[22:16] <= d_i[6:0];
         if (wr && d_addr == 7'h7D)
         begin
            en      <= d_i[0];
            rst_act <= d_i[1];
            ie      <= d_i[2];
            if (d_i[3])
               fault <= 1'b0;
         end
      end
   end

   always @*
   begin
   // the read decode is on d_addr[3:0]: lisa_periph.v gates d_o by the
   // 16-register group d_addr[6:4] (the two-level read decode, t6x4-8)
      case (d_addr[3:0])
      4'hA:   d_o = lim[7:0];
      4'hB:   d_o = lim[15:8];
      4'hC:   d_o = {1'b0, lim[22:16]};
      4'hD:   d_o = {4'h0, fault, ie, rst_act, en};
      default: d_o = 8'h00;
      endcase
   end

endmodule
