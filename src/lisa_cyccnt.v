/*
==============================================================================
lisa_cyccnt.v:  A 32-bit cycle counter for the LISA core (RESPIN 36).

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


A free-running 32-bit count of clocks, for timing and profiling: at
50 MHz it wraps every 86 s.  Reading the low byte latches the upper three,
so the four reads are one value; a write to the low byte clears it.

   0x48  CYC0   bits 7:0 (a read latches 31:8; a write clears the counter)
   0x49  CYC1   bits 15:8 as latched
   0x4A  CYC2   bits 23:16 as latched
   0x4B  CYC3   bits 31:24 as latched
*/

module lisa_cyccnt
(
   input  wire          clk,
   input  wire          rst_n,

   input  wire [6:0]    d_addr,
   input  wire [7:0]    d_i,
   input  wire          d_periph,
   input  wire          d_we,
   input  wire          d_rd,
   output reg  [7:0]    d_o
);

   reg   [31:0]   cnt;
   reg   [23:0]   hold;                // bits 31:8, latched by the CYC0 read

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         cnt  <= 32'h0;
         hold <= 24'h0;
      end
      else
      begin
         if (d_periph && d_we && d_addr == 7'h48)
            cnt <= 32'h0;
         else
            cnt <= cnt + 32'h1;
         if (d_periph && d_rd && d_addr == 7'h48)
            hold <= cnt[31:8];
      end
   end

   always @*
   begin
      case (d_addr)
      7'h48:   d_o = cnt[7:0];
      7'h49:   d_o = hold[7:0];
      7'h4A:   d_o = hold[15:8];
      7'h4B:   d_o = hold[23:16];
      default: d_o = 8'h0;
      endcase
   end

endmodule
