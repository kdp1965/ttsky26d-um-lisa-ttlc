/*
==============================================================================
lisa_div.v:  Little ISA (LISA) hardware 16-bit divider.

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

==============================================================================
*/

`define XPR_LEN            16
`define DOUBLE_XPR_LEN     32
`define LOG2_XPR_LEN        4

module lisa_div
#(
      parameter PC_BITS        = 12,
      parameter X_BITS         = 23        // IX and RA (REV3.md): their low 16 bits are the divider's b and result
 )
(
   input                clk, rst_n,
   input                reset,        // Positive synchronous reset
                        
   (* keep = "true" *)
   input                op_start,
   input                op_div,       // signed quotient
   input                op_rem,       // signed remainder
   input                op_remu,      // unsigned remainder (none set: unsigned quotient)
   input                op_chain,     // divc: {IX, div_rs1[7:0]} / the divisor kept from the last division (RESPIN 27)
   (* keep = "true" *)
   input       [15:0]   div_rs1,      // Dividend
   (* keep = "true" *)
   input       [15:0]   div_rs2,      // Divisor
   output wire [15:0]   div_rd,
   output wire          div_ready,

   // Flop sharing
   output wire          cflag,
   output wire          signed_inversion,
   input                cflag_val,
   input                signed_inv_val,
   input                cflag_load,
   output wire          zflag,
   input                zflag_val,
   input                zflag_load,
   output [X_BITS-1:0]  ix,
   output               ix_cond,
   input  [X_BITS-1:0]  ix_val,
   input                ix_cond_val,
   input                ix_load,
   output [X_BITS-1:0]  ra,
   output               ra_cond,
   input  [X_BITS-1:0]  ra_val,
   input                ra_cond_val,
   input                ra_load,
   output               ldx_stage_two,
   input                ldx_stage_two_val,
   input                ldx_stage_two_load
);
   /*
   A restoring divider (RESPIN 27, 2026-10-19; until then repeated
   subtraction in steps of the divisor shifted by 10, 7, 4 and 0 bits,
   10 to 95 clocks).  The dividend's magnitude sits in `result` and shifts
   out at the top, one bit a clock, into the remainder `b`; when the
   divisor fits it comes out and a one shifts into the bottom of `result`
   - which holds the quotient after 16 clocks.  `b` and `result` are the
   core's IX and RA (flop sharing: the core loads them here while the
   divider is idle).

   Both results come out of every division: div leaves the quotient in
   RA (and its low byte in A) and the remainder in IX, rem the other way
   round (TT07 and rc10 cleared IX).  The divisor's magnitude is kept in
   `a`, and divc (op_chain) divides {IX, the byte in div_rs1[7:0]} by it
   in 8 clocks: the quotient byte to RA / A, the remainder to IX - the
   step of a long division of any width by a 16-bit divisor, the
   remainder carried in IX.  IX must be below the divisor at a divc (it
   is after a division by the same divisor); the step is unsigned.

   Signed (amode[1]) as C: the quotient negative when the signs differ,
   the remainder with the dividend's sign (the earlier RTL gave the
   remainder the divisor's sign).  By zero: the quotient all ones, the
   remainder the dividend.  -32768 / -1 = -32768.
   */
   wire op_any_rem = op_rem | op_remu;
   wire op_signed  = op_div | op_rem;

   wire div_start = op_start;

   localparam md_state_width = 2;
   localparam [1:0] s_idle = 0;
   localparam [1:0] s_compute = 1;
   localparam [1:0] s_setup_output = 2;
   localparam [1:0] s_done = 3;

   reg [md_state_width-1:0]      state;
   reg [`XPR_LEN-1:0]            a;        // the divisor's magnitude, kept for divc
   reg [`XPR_LEN-1:0]            b;        // the remainder: IX
   reg [`XPR_LEN-1:0]            result;   // the dividend out, the quotient in: RA
   reg [3:0]                     count;
   reg                           neg_q;
   reg                           neg_r;
   reg                           is_rem;
   reg                           cond;
   reg                           ldx_stage_two_r;
   reg                           zflag_r;
   reg                           cflag_r;

   function [`XPR_LEN-1:0] abs_input;
      input [`XPR_LEN-1:0]                          data;
      input                                         is_signed;
      begin
         abs_input = (data[`XPR_LEN-1] == 1'b1 && is_signed) ? -data : data;
      end
   endfunction 

   wire [`XPR_LEN-1:0]           abs_dd  = abs_input(div_rs1, op_signed);
   wire [`XPR_LEN-1:0]           abs_dv  = abs_input(div_rs2, op_signed);
   wire                          sign_dd = op_signed & div_rs1[`XPR_LEN-1];
   wire                          sign_dv = op_signed & div_rs2[`XPR_LEN-1];
   wire                          dv_zero = div_rs2 == {`XPR_LEN{1'b0}};

   // one step: the next dividend bit into the remainder, the divisor out if it fits
   wire [`XPR_LEN:0]             trial   = {b, result[`XPR_LEN-1]} - {1'b0, a};
   wire                          fits    = ~trial[`XPR_LEN];

   wire [`XPR_LEN-1:0]           q_fin   = neg_q ? -result : result;
   wire [`XPR_LEN-1:0]           r_fin   = neg_r ? -b : b;
   wire [`XPR_LEN-1:0]           ra_fin  = is_rem ? r_fin : q_fin;
   wire [`XPR_LEN-1:0]           ix_fin  = is_rem ? q_fin : r_fin;

   assign zflag            = zflag_r;
   assign cflag            = cflag_r;
   assign signed_inversion = result[15];
   // IX: {cond, 22:16} in ix_hi, 15:0 in b; RA: 22:15 in ra_hi, 14:0 in
   // result, the condition bit in cond (result[15] is signed_inversion)
   reg  [7:0]                    ix_hi;
   reg  [7:0]                    ra_hi;
   assign ix               = {ix_hi[6:0], b};
   assign ix_cond          = ix_hi[7];
   assign ra               = {ra_hi, result[PC_BITS-1:0]};
   assign ra_cond          = cond;
   assign ldx_stage_two    = ldx_stage_two_r & (state == s_idle);

   assign div_ready = (state == s_done);
   assign div_rd = result[`XPR_LEN-1:0];

   always @(posedge clk)
   begin
      if (!rst_n || reset)
      begin
         state         <= s_idle;
         a             <= 'd0;
         result        <= 'd0;
         b             <= 'd0;
         count         <= 'd0;
         neg_q         <= 1'b0;
         neg_r         <= 1'b0;
         is_rem        <= 1'b0;
         cond          <= 1'b0;
         ix_hi         <= 8'h0;
         ra_hi         <= 8'h0;
         zflag_r       <= 1'b0;
         cflag_r       <= 1'b0;
         ldx_stage_two_r <= 1'b0;    // never reset before: X in icarus (random on
                                     // silicon) until the first ldx wrote it, and
                                     // ~ldx_stage_two gates the predicate update -
                                     // rev 3 starts with ldxf, so its first `if`
                                     // never took (CI's test_bringup, 2026-10-20)
      end
      else
      begin
         case (state)
            s_idle : begin
               if (div_start) 
               begin
                  state  <= s_compute;
                  is_rem <= op_any_rem;
                  if (op_chain)
                  begin
                     // a and b stay: the last divisor, the remainder in IX
                     result <= {div_rs1[7:0], 8'h00};
                     count  <= 4'd7;
                     neg_q  <= 1'b0;
                     neg_r  <= 1'b0;
                  end
                  else
                  begin
                     a      <= abs_dv;
                     b      <= {`XPR_LEN{1'b0}};
                     result <= abs_dd;
                     count  <= 4'd15;
                     neg_q  <= (sign_dd ^ sign_dv) & ~dv_zero;
                     neg_r  <= sign_dd;
                  end
               end
               else 
               begin 
                  if (ra_load)
                  begin
                     {cond, result[PC_BITS-1:0]} <= {ra_cond_val, ra_val[PC_BITS-1:0]};
                     ra_hi <= ra_val[X_BITS-1:PC_BITS];
                  end

                  if (cflag_load)
                  begin
                     cflag_r    <= cflag_val;
                     result[15] <= signed_inv_val;
                  end

                  if (zflag_load)
                     zflag_r <= zflag_val;

                  if (ix_load)
                  begin
                     b     <= ix_val[15:0];
                     ix_hi <= {ix_cond_val, ix_val[X_BITS-1:16]};
                  end

                  if (ldx_stage_two_load)
                     ldx_stage_two_r <= ldx_stage_two_val;
               end
            end
           
            s_compute : begin
               b      <= fits ? trial[`XPR_LEN-1:0] : {b[`XPR_LEN-2:0], result[`XPR_LEN-1]};
               result <= {result[`XPR_LEN-2:0], fits};
               count  <= count - 4'd1;
               if (count == 4'd0)
                  state <= s_setup_output;
            end // case: s_compute

            s_setup_output : 
            begin
               // the 16-bit result in RA: bits 14:0 in ra, bit 15 as RA[15] and
               // as ra_cond, so xchg ra / txau read it whole; the other one in
               // IX, its upper byte 0 (REV3.md)
               result <= ra_fin;
               b      <= ix_fin;
               cond   <= ra_fin[15];
               ra_hi  <= {7'h0, ra_fin[15]};
               ix_hi  <= 8'h0;
               state  <= s_done;
            end

            s_done:
            begin
               // Go to IDLE state; b (IX) keeps the remainder (RESPIN 27:
               // TT07 and rc10 cleared it here)
               state <= s_idle;
            end
         endcase // case (state)
      end
   end // always @ (posedge clk)

endmodule
