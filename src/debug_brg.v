/*
================================================================================
debug_brg:   Debug Baud Rate Generator (the bit period in clocks, since the second chip)

Copyright 2024 by Ken Pettit <pettitkd@gmail.com>

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

================================================================================
*/

module debug_brg
  (
   // Timing and reset inputs
   input  wire                clk,              // System clock 
   input  wire                rst_n,            // Active low reset
   input  wire                wr,               // Write strobe for d (the autobaud's)
   input  wire [13:0]         d,                // The bit period in clocks
   input  wire                baud_set,         // Set the period from the external divider:
   input  wire [6:0]          baud_div,         //   a bit is 32 x (baud_div + 1) clocks
   output wire                baud_ref          // 16 rising edges a bit
   );

   // ================================================
   // Internal signals
   // ================================================
   reg   [13:0]      s_period;                  // The bit period in clocks
   reg   [14:0]      s_acc;                     // 32 x the clocks into this 32nd of a bit
   reg               s_baud_ref;                // Baud ref signal
   reg               s_wr_edge;                 // Write signal edge detect

   wire  [14:0]      s_acc_next = s_acc + 15'd32;

   assign baud_ref = s_baud_ref;

   // ================================================
   // Clocked block to capture the period: the autobaud's measurement
   // (any number of clocks, 32 or more), or the external divider
   // ================================================
   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         s_period  <= 14'd416;                   // 32 x 13, the TT07 default
         s_wr_edge <= 1'b0;
      end
      else
      begin
         // Latch data on rising wr edge
         if (wr & ~s_wr_edge)
            s_period <= d;
         else if (baud_set)
            s_period <= {baud_div, 5'h0} + 14'd32;

         // Create edge detector
         s_wr_edge <= wr;
      end
   end

   // ================================================
   // Generate the 16x baud reference: 32 toggles a bit, each when
   // another 32nd of the period has accumulated (the period need not be
   // a multiple of 32: a toggle is at most a clock early or late, and 32
   // of them come to exactly one period on average)
   // ================================================
   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         s_acc      <= 15'h0;
         s_baud_ref <= 1'b0;
      end
      else
      begin
         if (s_acc_next >= {1'b0, s_period})
         begin
            s_acc      <= s_acc_next - {1'b0, s_period};
            s_baud_ref <= ~s_baud_ref;
         end
         else
            s_acc <= s_acc_next;
      end
   end

endmodule
