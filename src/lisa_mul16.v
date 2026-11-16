/*
==============================================================================
lisa_mul16.v:  A 16 x 16 multiplier peripheral for the LISA core (RESPIN 40).

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


A 16 x 16 -> 32 multiplier with an accumulate, reached with one sta / lda
per byte (a peripheral, not an opcode): four stores start it, four loads
read the product.  It takes 4 bits of B a clock, so a product is 4 clocks
after the B_H write; the core's next load comes later than that.

   0x70  A_L      the multiplicand (r/w)
   0x71  A_H
   0x72  B_L      the multiplier (r/w); a write to B_H starts the multiply
   0x73  B_H
   0x74  P0       the 32-bit product, P0 the low byte (read only), or
   0x75  P1       with ACC the running sum P <= P + A x B.  Read while
   0x76  P2       BUSY: the previous value (P changes only in the clock
   0x77  P3       the product is complete)
   0x78  CTRL     [0] SIGNED  A, B and P two's complement
                  [1] ACC     P <= P + A x B instead of P <= A x B
                  [2] CLR     write 1: P <= 0 (reads 0)
                  [7] BUSY    a multiply is in progress (read only)
                  [6:3] read 0

The algorithm: a radix-16 shift-add.  Each of the 4 clocks takes one
4-bit digit of B (the low digit first), forms the 16 x 4 partial product
A x digit as the sum of four conditionally shifted copies of A (no array
multiplier) and adds it to the 16-bit running high part H in a 20-bit
adder: the low 4 bits of that sum are 4 finished bits of the product
(shifted into L), the upper 16 bits are the next H.  In the 4th clock P
takes {sum, L}.  ACC: the digit of P at the step's position goes into the
same sum, and P's high half into the 4th step's bits [19:4] (its carry
out is the 32-bit wrap).  SIGNED: A and H are sign-extended into the adder
and B's top digit is a two's complement digit (its bit 3 weighs -8, so
that term is subtracted), which makes A x B + P exact in 32-bit two's
complement without a negate; H never leaves 16 bits in either mode
(|H| <= 2^15 until the last step, whose high bits wrap).  The flops:
A 16, B 16, P 32, H 16, L 12, SIGNED, ACC, BUSY, step 2 = 97.

Timing: the B_H write is clock 0; the four steps are clocks 1-4; BUSY
reads 1 after clock 0 and 0 after clock 4, when P holds the product.
A write to B_H while BUSY restarts the multiply with the operands as they
are then (a product completing in that same clock is still stored).  A
CTRL write with CLR while BUSY clears P and abandons the multiply in
flight (BUSY clears).  SIGNED and ACC are read as the multiply proceeds
and A, B_L and the P digits are consumed one step at a time, so change
them only when not BUSY or follow them with the B_H write that restarts.
*/

module lisa_mul16
(
   input  wire          clk,
   input  wire          rst_n,
   input  wire [6:0]    d_addr,
   input  wire [7:0]    d_i,
   input  wire          d_periph,
   input  wire          d_we,
   /* verilator lint_off UNUSEDSIGNAL */
   input  wire          d_rd,               // no read has a side effect
   /* verilator lint_on UNUSEDSIGNAL */
   output reg  [7:0]    d_o
);

   reg   [15:0]   a;                   // the multiplicand
   reg   [15:0]   b;                   // the multiplier
   reg   [31:0]   p;                   // the product / accumulator
   reg   [15:0]   h;                   // the running sum's high part
   reg   [11:0]   l;                   // the finished low digits of steps 0-2
   reg            sgn;                 // CTRL[0] SIGNED
   reg            acc;                 // CTRL[1] ACC
   reg            busy;
   reg   [1:0]    step;                // which digit of B this clock takes
   reg   [3:0]    dig;                 // B's digit
   reg   [3:0]    pdig;                // P's digit at the same position
   wire           wr;
   wire           start;
   wire           last;
   wire           dneg;                // the digit is two's complement
   wire  [19:0]   a_x, h_x;            // A and H extended for the adder
   wire  [19:0]   t0, t1, t2, t3, a8;  // A x the digit, a bit at a time
   wire  [19:0]   phi;                 // P's high half, in the last step
   wire  [19:0]   sum;

   assign wr    = d_periph && d_we;
   assign start = wr && d_addr == 7'h73;
   assign last  = step == 2'd3;
   assign dneg  = sgn && last;
   assign a_x   = {{4{sgn && a[15]}}, a};
   assign h_x   = {{4{sgn && h[15]}}, h};
   assign t0    = dig[0] ? a_x               : 20'h0;
   assign t1    = dig[1] ? {a_x[18:0], 1'b0} : 20'h0;
   assign t2    = dig[2] ? {a_x[17:0], 2'b0} : 20'h0;
   assign a8    = {a_x[16:0], 3'b0};
   assign t3    = dig[3] ? (dneg ? -a8 : a8) : 20'h0;
   assign phi   = {(acc && last) ? p[31:16] : 16'h0, 4'h0};
   assign sum   = h_x + t0 + t1 + t2 + t3 + {16'h0, pdig} + phi;

   always @*
   begin
      case (step)
      2'd0:    dig = b[3:0];
      2'd1:    dig = b[7:4];
      2'd2:    dig = b[11:8];
      default: dig = b[15:12];
      endcase
      case (step)
      2'd0:    pdig = p[3:0];
      2'd1:    pdig = p[7:4];
      2'd2:    pdig = p[11:8];
      default: pdig = p[15:12];
      endcase
      if (!acc)
         pdig = 4'h0;
   end

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         a    <= 16'h0;
         b    <= 16'h0;
         p    <= 32'h0;
         h    <= 16'h0;
         l    <= 12'h0;
         sgn  <= 1'b0;
         acc  <= 1'b0;
         busy <= 1'b0;
         step <= 2'h0;
      end
      else
      begin
         if (wr && d_addr == 7'h70) a[7:0]  <= d_i;
         if (wr && d_addr == 7'h71) a[15:8] <= d_i;
         if (wr && d_addr == 7'h72) b[7:0]  <= d_i;
         if (wr && d_addr == 7'h78)
         begin
            sgn <= d_i[0];
            acc <= d_i[1];
         end

         // the multiply: a B_H write (re)starts it, then a digit a clock
         if (start)
         begin
            b[15:8] <= d_i;
            busy    <= 1'b1;
            step    <= 2'h0;
            h       <= 16'h0;
         end
         else if (busy)
         begin
            h    <= sum[19:4];
            l    <= {sum[3:0], l[11:4]};
            step <= step + 2'h1;
            if (last)
               busy <= 1'b0;
         end

         // the product lands in the 4th step (even when a restart is
         // written in that clock); CLR clears P and abandons a multiply
         if (wr && d_addr == 7'h78 && d_i[2])
         begin
            p    <= 32'h0;
            busy <= 1'b0;
         end
         else if (busy && last)
            p <= {sum, l};
      end
   end

   always @*
   begin
   // the read decode is on d_addr[3:0]: lisa_periph.v gates d_o by the
   // 16-register group d_addr[6:4] (the two-level read decode, t6x4-8)
      case (d_addr[3:0])
      4'h0:   d_o = a[7:0];
      4'h1:   d_o = a[15:8];
      4'h2:   d_o = b[7:0];
      4'h3:   d_o = b[15:8];
      4'h4:   d_o = p[7:0];
      4'h5:   d_o = p[15:8];
      4'h6:   d_o = p[23:16];
      4'h7:   d_o = p[31:24];
      4'h8:   d_o = {busy, 5'h0, acc, sgn};
      default: d_o = 8'h0;
      endcase
   end

endmodule
