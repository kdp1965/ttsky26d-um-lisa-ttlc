/*
==============================================================================
lisa_plc.v:  The PLC timer / counter block for the LISA core (RESPIN 40).

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


NT timers and NC counters - six and four (eight and eight until the 6x4
trial of 2026-11-15, where the 8 + 8 block was 37k um2, a third of what
RESPIN 40 added; then four and four) - in an I/O layout of eight slots of
each kind, a slot with no block reading 0 and taking no write: the
function blocks of IEC ladder logic that the MC14500B's bit logic cannot
do by itself (Ken, 2026-11-14).  The TTLC drives a timer's IN by writing
I/O address 139 + n and a counter's CU by writing 147 + n (ttlc_io.v
hands the write over as plc_we / plc_addr /
plc_bit); the bit written is held and ORed with the core's own LISA_IN /
LISA_CU bit of TC_CTRL.  The TTLC reads the Q outputs back at the same
addresses (t_done, c_done), the core as T_DONE / C_DONE.  Counter n's
reset R is storage bit 120 + n (cnt_rst) or the RST bit of TC_CTRL.

   0x50  TC_IDX      [3:0] the block the next five registers address:
                     0-7 timer n, 8-15 counter n - 8
   0x51  TC_CTRL     timer:   [0] MODE (0 TON on-delay, 1 TOF off-delay),
                     [2:1] BASE (0 1 ms, 1 10 ms, 2 100 ms, 3 1 s), [3] Q
                     (ro), [4] IN (ro: the TTLC's bit | LISA_IN), [5]
                     LISA_IN (r/w)
                     counter: [0] MODE (0 up, 1 down), [3] Q (ro), [4] CU
                     (ro: the TTLC's bit | LISA_CU), [5] LISA_CU (r/w: a
                     rising edge counts), [6] RST (write 1: reset; reads 0)
   0x52  TC_PRESET_L the preset in ticks of the timer's base, or the
   0x53  TC_PRESET_H counter's preset (reset 0)
   0x54  TC_VALUE_L  the timer's elapsed ticks or the count (read only);
   0x55  TC_VALUE_H  reading L latches H
   0x56  T_DONE      the timers' Q, bit n timer n (read only; an empty slot 0)
   0x57  C_DONE      the counters' Q (read only; an empty slot 0)
   0x58  TC_PRE_L    clocks per 1 ms tick, less one (reset 49999 = 0xC34F
   0x59  TC_PRE_H    at 50 MHz); a write restarts the tick generator

TON: while IN is high the value counts the ticks of the base up to the
preset and stops there; Q = IN & (value >= preset) (a preset of 0: Q
follows IN); IN low clears the value and Q.  TOF: IN high: Q = 1, value
0; when IN falls the value counts up to the preset and Q stays 1 until it
gets there (the value then holds the preset until IN rises again); the
off delay starts only at a fall of IN, so a timer put into TOF mode with
IN low does not pulse Q.  The compare is >= rather than ==, which is the
same thing until a preset is lowered under a running value: then Q comes
at once instead of never.  Counter up: a rising edge of CU adds one (saturating
at 0xFFFF); Q = (count >= preset); R clears the count.  Counter down: R
loads the preset, an edge subtracts one (saturating at 0); Q = (count ==
0).  R held high holds the counter in reset (and a RST write that also
changes MODE loads for the mode written).

One tick generator serves all the timers: the prescaler divides the clock
by TC_PRE + 1 into the 1 ms tick, a /10 chain makes the 10 ms, 100 ms and
1 s ticks from it; each tick is a one-clock pulse (a flop).  A timer's
ticks are quantised by its base: Q comes PRESET - 1 to PRESET tick
periods after IN.  The Q outputs are flops: one clock behind the value.
*/

module lisa_plc
#(
   parameter NT = 6,                   // timers: slots 0 .. NT-1 of 8
   parameter NC = 4                    // counters: slots 8 .. 8+NC-1 of 16
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
   input  wire          plc_we,       // one clock: the TTLC wrote I/O address 139 + plc_addr
   input  wire [3:0]    plc_addr,     // 0-7 timer n (its IN), 8-15 counter n-8 (its CU)
   input  wire          plc_bit,      // the bit written
   input  wire [7:0]    cnt_rst,      // counter n's R: storage bit 120 + n (a level)
   output wire [7:0]    t_done,       // the timers' Q (TTLC addresses 139-146, T_DONE)
   output wire [7:0]    c_done        // the counters' Q (147-154, C_DONE)
);

   // the registers shared by the blocks
   reg   [3:0]    idx;                 // TC_IDX
   reg   [15:0]   tc_pre;              // TC_PRE
   reg   [7:0]    val_hold;            // TC_VALUE_H: latched by the TC_VALUE_L read

   // the tick generator
   reg   [15:0]   pre_cnt;             // 0 .. TC_PRE
   reg   [3:0]    d10a, d10b, d10c;    // the /10 chain: 10 ms, 100 ms, 1 s
   reg   [3:0]    tick;                // one clock each: [0] 1 ms, [1] 10 ms, [2] 100 ms, [3] 1 s
   wire           hit_1ms, hit_10ms, hit_100ms, hit_1s;

   // the bus
   wire           wr;
   wire           wr_ctrl, wr_preset_l, wr_preset_h, wr_tcpre;
   wire  [15:0]   sel;                 // the block TC_IDX selects: [7:0] timers, [15:8] counters

   // the per-block state, flattened for the read mux (block k at [k*16 +: 16], [k*2 +: 2], [k])
   wire  [127:0]  t_val_bus, t_preset_bus, c_cnt_bus, c_preset_bus;
   wire  [15:0]   t_base_bus;
   wire  [7:0]    t_mode_bus, t_in_bus, t_lisa_bus;
   wire  [7:0]    c_mode_bus, c_cu_bus, c_lisa_bus;
   wire  [15:0]   value_sel, preset_sel;
   wire  [7:0]    ctrl_sel;

   assign wr          = d_periph && d_we;
   assign wr_ctrl     = wr && d_addr == 7'h51;
   assign wr_preset_l = wr && d_addr == 7'h52;
   assign wr_preset_h = wr && d_addr == 7'h53;
   assign wr_tcpre    = wr && (d_addr == 7'h58 || d_addr == 7'h59);
   assign sel         = 16'h1 << idx;

   assign hit_1ms   = pre_cnt == tc_pre;
   assign hit_10ms  = hit_1ms   && d10a == 4'd9;
   assign hit_100ms = hit_10ms  && d10b == 4'd9;
   assign hit_1s    = hit_100ms && d10c == 4'd9;

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         idx      <= 4'h0;
         tc_pre   <= 16'hC34F;
         val_hold <= 8'h0;
         pre_cnt  <= 16'h0;
         d10a     <= 4'h0;
         d10b     <= 4'h0;
         d10c     <= 4'h0;
         tick     <= 4'h0;
      end
      else
      begin
         if (wr && d_addr == 7'h50) idx          <= d_i[3:0];
         if (wr && d_addr == 7'h58) tc_pre[7:0]  <= d_i;
         if (wr && d_addr == 7'h59) tc_pre[15:8] <= d_i;
         if (d_periph && d_rd && d_addr == 7'h54)
            val_hold <= value_sel[15:8];

         // the tick generator; a TC_PRE write restarts it
         if (wr_tcpre)
         begin
            pre_cnt <= 16'h0;
            d10a    <= 4'h0;
            d10b    <= 4'h0;
            d10c    <= 4'h0;
            tick    <= 4'h0;
         end
         else
         begin
            pre_cnt <= hit_1ms ? 16'h0 : pre_cnt + 16'h1;
            if (hit_1ms)   d10a <= hit_10ms  ? 4'h0 : d10a + 4'h1;
            if (hit_10ms)  d10b <= hit_100ms ? 4'h0 : d10b + 4'h1;
            if (hit_100ms) d10c <= hit_1s    ? 4'h0 : d10c + 4'h1;
            tick <= {hit_1s, hit_100ms, hit_10ms, hit_1ms};
         end
      end
   end

   // ==========================================================================
   // The timers
   // ==========================================================================
   genvar k;
   generate
   for (k = 0; k < NT; k = k + 1)
   begin : tmr
      localparam [3:0] ADDR = k;       // its plc_addr

      reg   [15:0]   preset;
      reg   [15:0]   val;
      reg            mode;             // 0 TON, 1 TOF
      reg   [1:0]    base;
      reg            lisa_in;          // the core's input
      reg            ttlc_in;          // the TTLC's last write to 139 + k
      reg            armed;            // TOF: IN has been high and the off delay has not expired
      reg            q;
      wire           in;
      wire           clr;              // the phase that holds the value at 0: TON IN low, TOF IN high
      wire           run;              // the phase that counts: TON IN high, TOF the off delay
      wire           done;             // value >= preset

      assign in   = ttlc_in | lisa_in;
      assign clr  = mode ? in : ~in;
      assign run  = mode ? (armed & ~in) : in;
      assign done = val >= preset;

      always @(posedge clk)
      begin
         if (~rst_n)
         begin
            preset  <= 16'h0;
            val     <= 16'h0;
            mode    <= 1'b0;
            base    <= 2'h0;
            lisa_in <= 1'b0;
            ttlc_in <= 1'b0;
            armed   <= 1'b0;
            q       <= 1'b0;
         end
         else
         begin
            if (plc_we && plc_addr == ADDR)
               ttlc_in <= plc_bit;
            if (wr_ctrl && sel[k])
            begin
               mode    <= d_i[0];
               base    <= d_i[2:1];
               lisa_in <= d_i[5];
            end
            if (wr_preset_l && sel[k]) preset[7:0]  <= d_i;
            if (wr_preset_h && sel[k]) preset[15:8] <= d_i;

            // the value counts the base's ticks up to the preset while the
            // timer runs, and is cleared in the other phase (a TOF that has
            // expired holds it at the preset until IN rises again)
            if (clr)
               val <= 16'h0;
            else if (run && tick[base] && !done)
               val <= val + 16'h1;

            // TOF only: armed while IN is high, until the off delay expires -
            // so a timer put into TOF mode with IN low does not pulse Q
            armed <= mode & (in | (armed & ~done));

            // TON: Q = IN & done; TOF: Q = IN | (the off delay running)
            q <= mode ? (in | (armed & ~done)) : (in & done);
         end
      end

      assign t_done[k]                = q;
      assign t_val_bus[k*16 +: 16]    = val;
      assign t_preset_bus[k*16 +: 16] = preset;
      assign t_base_bus[k*2 +: 2]     = base;
      assign t_mode_bus[k]            = mode;
      assign t_in_bus[k]              = in;
      assign t_lisa_bus[k]            = lisa_in;
   end
   // the empty timer slots read 0
   for (k = NT; k < 8; k = k + 1)
   begin : tmr_none
      assign t_done[k]                = 1'b0;
      assign t_val_bus[k*16 +: 16]    = 16'h0;
      assign t_preset_bus[k*16 +: 16] = 16'h0;
      assign t_base_bus[k*2 +: 2]     = 2'h0;
      assign t_mode_bus[k]            = 1'b0;
      assign t_in_bus[k]              = 1'b0;
      assign t_lisa_bus[k]            = 1'b0;
   end
   endgenerate

   // ==========================================================================
   // The counters
   // ==========================================================================
   generate
   for (k = 0; k < NC; k = k + 1)
   begin : ctr
      localparam [3:0] ADDR = k + 8;   // its plc_addr

      reg   [15:0]   preset;
      reg   [15:0]   cnt;
      reg            mode;             // 0 up, 1 down
      reg            lisa_cu;          // the core's count input
      reg            ttlc_cu;          // the TTLC's last write to 147 + k
      reg            cu_last;
      reg            q;
      wire           cu;
      wire           rise;             // a rising edge of CU
      wire           wr_me;            // a TC_CTRL write to this counter
      wire           mode_now;         // the mode, or the one being written this clock
      wire           r;                // the reset: storage bit 120 + k, or a RST write
      wire           zero, full;

      assign cu       = ttlc_cu | lisa_cu;
      assign rise     = cu & ~cu_last;
      assign wr_me    = wr_ctrl && sel[k + 8];
      assign mode_now = wr_me ? d_i[0] : mode;
      assign r        = cnt_rst[k] | (wr_me && d_i[6]);
      assign zero     = cnt == 16'h0;
      assign full     = cnt == 16'hFFFF;

      always @(posedge clk)
      begin
         if (~rst_n)
         begin
            preset  <= 16'h0;
            cnt     <= 16'h0;
            mode    <= 1'b0;
            lisa_cu <= 1'b0;
            ttlc_cu <= 1'b0;
            cu_last <= 1'b0;
            q       <= 1'b0;
         end
         else
         begin
            if (plc_we && plc_addr == ADDR)
               ttlc_cu <= plc_bit;
            if (wr_me)
            begin
               mode    <= d_i[0];
               lisa_cu <= d_i[5];
            end
            if (wr_preset_l && sel[k + 8]) preset[7:0]  <= d_i;
            if (wr_preset_h && sel[k + 8]) preset[15:8] <= d_i;
            cu_last <= cu;

            // R: up clears, down loads the preset; else an edge counts,
            // saturating
            if (r)
               cnt <= mode_now ? preset : 16'h0;
            else if (rise)
            begin
               if (mode)
               begin
                  if (!zero) cnt <= cnt - 16'h1;
               end
               else if (!full)
                  cnt <= cnt + 16'h1;
            end

            // up: Q = count >= preset; down: Q = count == 0
            // a counter with preset 0 is off (Q = 0): the reset state of an
            // unconfigured block reads 0 in the I/O space (IEC's CTU with PV 0
            // would have Q = 1)
            q <= (preset != 16'h0) & (mode ? zero : (cnt >= preset));
         end
      end

      assign c_done[k]                = q;
      assign c_cnt_bus[k*16 +: 16]    = cnt;
      assign c_preset_bus[k*16 +: 16] = preset;
      assign c_mode_bus[k]            = mode;
      assign c_cu_bus[k]              = cu;
      assign c_lisa_bus[k]            = lisa_cu;
   end
   // the empty counter slots read 0
   for (k = NC; k < 8; k = k + 1)
   begin : ctr_none
      assign c_done[k]                = 1'b0;
      assign c_cnt_bus[k*16 +: 16]    = 16'h0;
      assign c_preset_bus[k*16 +: 16] = 16'h0;
      assign c_mode_bus[k]            = 1'b0;
      assign c_cu_bus[k]              = 1'b0;
      assign c_lisa_bus[k]            = 1'b0;
   end
   endgenerate

   // ==========================================================================
   // The read side: the selected block's registers
   // ==========================================================================
   assign value_sel  = idx[3] ? c_cnt_bus[{idx[2:0], 4'h0} +: 16]
                              : t_val_bus[{idx[2:0], 4'h0} +: 16];
   assign preset_sel = idx[3] ? c_preset_bus[{idx[2:0], 4'h0} +: 16]
                              : t_preset_bus[{idx[2:0], 4'h0} +: 16];
   assign ctrl_sel   = idx[3] ? {2'b00, c_lisa_bus[idx[2:0]], c_cu_bus[idx[2:0]],
                                 c_done[idx[2:0]], 2'b00, c_mode_bus[idx[2:0]]}
                              : {2'b00, t_lisa_bus[idx[2:0]], t_in_bus[idx[2:0]],
                                 t_done[idx[2:0]], t_base_bus[{idx[2:0], 1'b0} +: 2],
                                 t_mode_bus[idx[2:0]]};

   always @*
   begin
   // the read decode is on d_addr[3:0]: lisa_periph.v gates d_o by the
   // 16-register group d_addr[6:4] (the two-level read decode, t6x4-8)
      case (d_addr[3:0])
      4'h0:   d_o = {4'h0, idx};
      4'h1:   d_o = ctrl_sel;
      4'h2:   d_o = preset_sel[7:0];
      4'h3:   d_o = preset_sel[15:8];
      4'h4:   d_o = value_sel[7:0];
      4'h5:   d_o = val_hold;
      4'h6:   d_o = t_done;
      4'h7:   d_o = c_done;
      4'h8:   d_o = tc_pre[7:0];
      4'h9:   d_o = tc_pre[15:8];
      default: d_o = 8'h0;
      endcase
   end

endmodule
