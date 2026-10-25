/*
==============================================================================
lisa_pdm.v:  Two PDM (sigma-delta) outputs for the LISA core (RESPIN 36).

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

Two first-order sigma-delta modulators: each clock a channel adds its
8-bit level to an 8-bit accumulator and outputs the carry, so the output's
density of 1s is VAL / 256.  Through an RC low-pass (for audio, 1 kOhm and
10 nF: 16 kHz) it is an 8-bit DAC; the noise is pushed up to the clock
rate.  An enabled channel drives Timer 3's PWM pin in uo_out mux 2 (uo[1]
channel 0, uo[2] channel 1) in place of the PWM (lisa_periph.v).

   0x50  PDM_CTRL  [0] channel 0 on, [1] channel 1 on
   0x51  PDM_VAL0  channel 0's level
   0x52  PDM_VAL1  channel 1's level
*/

module lisa_pdm
(
   input  wire          clk,
   input  wire          rst_n,

   input  wire [6:0]    d_addr,
   input  wire [7:0]    d_i,
   input  wire          d_periph,
   input  wire          d_we,
   output reg  [7:0]    d_o,

   output wire [1:0]    pdm,           // the bit streams ...
   output wire [1:0]    pdm_en         // ... and the channels on
);

   reg   [1:0]    en;
   reg   [7:0]    val0, val1;
   reg   [8:0]    acc0, acc1;          // bit 8: the output bit
   wire           wr = d_periph && d_we;

   assign pdm    = {acc1[8], acc0[8]} & en;
   assign pdm_en = en;

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         en   <= 2'b00;
         val0 <= 8'h0;
         val1 <= 8'h0;
         acc0 <= 9'h0;
         acc1 <= 9'h0;
      end
      else
      begin
         if (wr && d_addr == 7'h50) en   <= d_i[1:0];
         if (wr && d_addr == 7'h51) val0 <= d_i;
         if (wr && d_addr == 7'h52) val1 <= d_i;
         acc0 <= {1'b0, acc0[7:0]} + {1'b0, val0};
         acc1 <= {1'b0, acc1[7:0]} + {1'b0, val1};
      end
   end

   always @*
   begin
      case (d_addr)
      7'h50:   d_o = {6'h0, en};
      7'h51:   d_o = val0;
      7'h52:   d_o = val1;
      default: d_o = 8'h0;
      endcase
   end

endmodule
