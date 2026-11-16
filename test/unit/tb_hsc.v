// tb_hsc.v: the high-speed / quadrature counter (src/lisa_hsc.v) on its
// own, both instances of the chip (HSC0 at 0x60, HSC1 at 0x68) on one bus.
// The bus is driven the way the core drives it: d_we / d_rd one clock, an
// access every few clocks, d_o sampled in the strobe's clock.  ui_in is
// driven at the falling edge.  Self-checking: PASS / FAIL per check, then
// ALL PASSED or SOME FAILED.   make hsc   (iverilog -g2012)

`timescale 1ns/1ps

module tb_hsc;

   reg            clk = 1'b0;
   reg            rst_n = 1'b0;
   reg   [6:0]    d_addr = 7'h0;
   reg   [7:0]    d_i = 8'h0;
   reg            d_periph = 1'b0;
   reg            d_we = 1'b0;
   reg            d_rd = 1'b0;
   reg   [7:0]    ui_in = 8'h0;
   wire  [7:0]    d_o0, d_o1, d_o;
   wire           irq0, irq1, ge0, ge1;

   integer        n_pass = 0;
   integer        n_fail = 0;

   always #10 clk = ~clk;              // 50 MHz

   lisa_hsc #(.BASE(7'h60)) hsc0
   (
      .clk      ( clk      ),
      .rst_n    ( rst_n    ),
      .d_addr   ( d_addr   ),
      .d_i      ( d_i      ),
      .d_periph ( d_periph ),
      .d_we     ( d_we     ),
      .d_rd     ( d_rd     ),
      .d_o      ( d_o0     ),
      .ui_in    ( ui_in    ),
      .irq      ( irq0     ),
      .ge       ( ge0      )
   );

   lisa_hsc #(.BASE(7'h68)) hsc1
   (
      .clk      ( clk      ),
      .rst_n    ( rst_n    ),
      .d_addr   ( d_addr   ),
      .d_i      ( d_i      ),
      .d_periph ( d_periph ),
      .d_we     ( d_we     ),
      .d_rd     ( d_rd     ),
      .d_o      ( d_o1     ),
      .ui_in    ( ui_in    ),
      .irq      ( irq1     ),
      .ge       ( ge1      )
   );

   assign d_o = d_o0 | d_o1;           // as lisa_periph.v ORs the blocks

   // the registers
   localparam [6:0] H0 = 7'h60, H1 = 7'h68;
   localparam [2:0] CTRL = 3'd0, STAT = 3'd1, CNT_L = 3'd2, CNT_H = 3'd3,
                    CMP_L = 3'd4, CMP_H = 3'd5;
   // CTRL bits
   localparam [7:0] M_PULSE = 8'h00, M_DIR = 8'h01, M_X1 = 8'h02, M_X4 = 8'h03,
                    EN = 8'h10, IE = 8'h20, CLR = 8'h40, FILT = 8'h80;
   // STAT bits
   localparam [7:0] S_MATCH = 8'h01, S_OVF = 8'h02, S_UNF = 8'h04, S_DIR = 8'h08,
                    S_A = 8'h10, S_B = 8'h20, S_GE = 8'h40;

   function [7:0] pins(input [1:0] p);
      pins = {4'h0, p, 2'h0};
   endfunction

   // ---------------------------------------------------------------- checks
   task check(input string name, input [31:0] got, input [31:0] exp);
      begin
         if (got === exp)
         begin
            n_pass = n_pass + 1;
            $display("PASS  %0s", name);
         end
         else
         begin
            n_fail = n_fail + 1;
            $display("FAIL  %0s: got 0x%0h, expected 0x%0h", name, got, exp);
         end
      end
   endtask

   // ---------------------------------------------------------------- the bus
   // Every task starts and ends at a falling edge of clk.
   task bus_wr(input [6:0] addr, input [7:0] v);
      begin
         d_addr = addr; d_i = v; d_periph = 1'b1; d_we = 1'b1;
         @(negedge clk);
         d_periph = 1'b0; d_we = 1'b0; d_addr = 7'h0; d_i = 8'h0;
         repeat (2) @(negedge clk);
      end
   endtask

   task bus_rd(input [6:0] addr, output [7:0] v);
      begin
         d_addr = addr; d_periph = 1'b1; d_rd = 1'b1;
         #8 v = d_o;                   // in the strobe's clock, before its edge
         @(negedge clk);
         d_periph = 1'b0; d_rd = 1'b0; d_addr = 7'h0;
         repeat (2) @(negedge clk);
      end
   endtask

   // a read of CNT_L then CNT_H: the latch, as a program reads the count
   task rd_cnt(input [6:0] base, output [15:0] v);
      reg [7:0] lo, hi;
      begin
         bus_rd(base | {4'h0, CNT_L}, lo);
         bus_rd(base | {4'h0, CNT_H}, hi);
         v = {hi, lo};
      end
   endtask

   task wr16(input [6:0] base, input [2:0] reg_l, input [15:0] v);
      begin
         bus_wr(base | {4'h0, reg_l + 3'd1}, v[15:8]);   // H first
         bus_wr(base | {4'h0, reg_l}, v[7:0]);
      end
   endtask

   task wait_clks(input integer n);
      begin
         repeat (n) @(negedge clk);
      end
   endtask

   // ---------------------------------------------------------------- the pins
   task set_ab(input [1:0] p, input a, input b);
      begin
         ui_in[2 * p]     = a;
         ui_in[2 * p + 1] = b;
         @(negedge clk);
      end
   endtask

   // n pulses on A of pair p, hi clocks high then lo clocks low
   task pulses(input [1:0] p, input integer n, input integer hi, input integer lo);
      integer i;
      begin
         for (i = 0; i < n; i = i + 1)
         begin
            ui_in[2 * p] = 1'b1;
            wait_clks(hi);
            ui_in[2 * p] = 1'b0;
            wait_clks(lo);
         end
      end
   endtask

   // n pulses on A of pair p while B toggles in the middle of each
   task pulses_b_toggling(input [1:0] p, input integer n, input integer half);
      integer i;
      begin
         for (i = 0; i < n; i = i + 1)
         begin
            ui_in[2 * p] = 1'b1;
            wait_clks(half);
            ui_in[2 * p + 1] = ~ui_in[2 * p + 1];
            wait_clks(half);
            ui_in[2 * p] = 1'b0;
            wait_clks(half);
            ui_in[2 * p + 1] = ~ui_in[2 * p + 1];
            wait_clks(half);
         end
      end
   endtask

   // quadrature: steps single-input transitions of pair p, dwell clocks
   // each; forward is {A, B} 00 -> 10 -> 11 -> 01 -> 00 (A leads B)
   task quad(input [1:0] p, input integer steps, input fwd, input integer dwell);
      integer i;
      reg a, b;
      begin
         a = ui_in[2 * p];
         b = ui_in[2 * p + 1];
         for (i = 0; i < steps; i = i + 1)
         begin
            if (fwd ^ (a != b)) a = ~a;
            else                b = ~b;
            ui_in[2 * p]     = a;
            ui_in[2 * p + 1] = b;
            wait_clks(dwell);
         end
      end
   endtask

   // ---------------------------------------------------------------- the test
   reg   [7:0]    v8;
   reg   [15:0]   v16;

   initial
   begin
      if ($test$plusargs("VCD"))
      begin
         $dumpfile("tb_hsc.vcd");
         $dumpvars(0, tb_hsc);
      end

      // reset
      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      @(negedge clk);

      // ---------------------------------------------------------- reset state
      bus_rd(H0 | {4'h0, CTRL}, v8);  check("reset: CTRL 0", v8, 8'h00);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("reset: STAT 0 (GE gated by EN)", v8, 8'h00);
      rd_cnt(H0, v16);                check("reset: CNT 0", v16, 16'h0000);
      bus_rd(H0 | {4'h0, CMP_L}, v8); check("reset: CMP_L 0", v8, 8'h00);
      bus_rd(H0 | {4'h0, CMP_H}, v8); check("reset: CMP_H 0", v8, 8'h00);
      check("reset: ge0 level 0 (EN clear)", ge0, 1'b0);
      check("reset: irq0 0", irq0, 1'b0);
      bus_rd(H0 | 3'd6, v8);          check("BASE+6 reads 0", v8, 8'h00);
      bus_rd(H0 | 3'd7, v8);          check("BASE+7 reads 0", v8, 8'h00);
      // an in-group address nobody owns: both d_o are 0 (d_o is their OR);
      // out-of-group addresses are lisa_periph's to mask (t6x4-8)
      wr16(H0, CMP_L, 16'hFFFF);
      bus_rd(7'h67, v8);              check("unowned in-group address 0x67 reads 0", v8, 8'h00);
      // the block decodes d_addr[3] and [2:0] on reads (the group 0x60-0x6F is
      // lisa_periph's, t6x4-8): the other HSC's and the unowned in-group addresses read 0
      bus_rd(7'h6C, v8);              check("the other HSC's address 0x6C reads 0", v8, 8'h00);
      bus_rd(7'h66, v8);              check("unowned in-group address 0x66 reads 0", v8, 8'h00);
      bus_rd(7'h6F, v8);              check("unowned in-group address 0x6F reads 0", v8, 8'h00);
      bus_rd(H1 | {4'h0, CMP_L}, v8); check("HSC0's CMP write did not reach HSC1", v8, 8'h00);
      wr16(H0, CMP_L, 16'h0000);

      // ---------------------------------------------------------- pulse mode
      set_ab(0, 0, 0);
      bus_wr(H0 | {4'h0, CTRL}, M_PULSE | pins(0) | EN);
      bus_rd(H0 | {4'h0, CTRL}, v8);  check("CTRL reads back EN, mode 0", v8, M_PULSE | pins(0) | EN);
      pulses(0, 10, 3, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("pulse: 10 pulses count 10 (rising edges only)", v16, 16'd10);
      pulses_b_toggling(0, 6, 3);
      set_ab(0, 0, 0);
      wait_clks(8);
      rd_cnt(H0, v16);                check("pulse: B is ignored (16 after 6 more)", v16, 16'd16);
      pulses(0, 4, 1, 1);
      wait_clks(8);
      rd_cnt(H0, v16);                check("pulse: 1-clock pulses count without FILT (20)", v16, 16'd20);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("pulse: STAT DIR 0, A 0, B 0, GE 1", v8, S_GE);
      // a different pair does not count
      pulses(2, 5, 3, 3);
      pulses(3, 5, 3, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("pulse: other pairs do not count (20)", v16, 16'd20);
      // EN off: nothing counts
      bus_wr(H0 | {4'h0, CTRL}, M_PULSE | pins(0));
      pulses(0, 5, 3, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("EN 0: no count (20)", v16, 16'd20);

      // ------------------------------------------------- pulses with direction
      bus_wr(H0 | {4'h0, CTRL}, M_DIR | pins(0) | EN);
      set_ab(0, 0, 1);                // B high: down
      wait_clks(8);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("dir: STAT shows B high", v8 & (S_A | S_B), S_B);
      pulses(0, 4, 3, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("dir: B high counts down (20 - 4 = 16)", v16, 16'd16);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("dir: DIR set after a step down", v8 & S_DIR, S_DIR);
      set_ab(0, 0, 0);                // B low: up
      pulses(0, 3, 3, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("dir: B low counts up (19)", v16, 16'd19);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("dir: DIR clear after a step up", v8 & S_DIR, 8'h00);

      // ---------------------------------------------------------------- CLR
      bus_wr(H0 | {4'h0, CTRL}, M_DIR | pins(0) | EN | CLR);
      rd_cnt(H0, v16);                check("CLR: count 0", v16, 16'h0000);
      bus_rd(H0 | {4'h0, CTRL}, v8);  check("CLR: reads 0, the other bits kept", v8, M_DIR | pins(0) | EN);

      // ------------------------------------------------------- quadrature x1
      bus_wr(H0 | {4'h0, CTRL}, M_X1 | pins(0) | EN);
      quad(0, 32, 1'b1, 3);           // 8 cycles forward
      wait_clks(8);
      rd_cnt(H0, v16);                check("x1: 8 cycles forward = +8", v16, 16'd8);
      quad(0, 20, 1'b0, 3);           // 5 cycles back
      wait_clks(8);
      rd_cnt(H0, v16);                check("x1: 5 cycles back = -5 (3)", v16, 16'd3);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("x1: DIR set after backward", v8 & S_DIR, S_DIR);
      quad(0, 4, 1'b1, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("x1: one more cycle forward (4)", v16, 16'd4);
      check("x1: pins back at 00", ui_in[1:0], 2'b00);

      // ------------------------------------------------------- quadrature x4
      bus_wr(H0 | {4'h0, CTRL}, M_X4 | pins(0) | EN | CLR);
      quad(0, 20, 1'b1, 3);           // 5 cycles forward = 20 steps
      wait_clks(8);
      rd_cnt(H0, v16);                check("x4: 5 cycles forward = +20", v16, 16'd20);
      quad(0, 3, 1'b1, 3);            // part of a cycle: every edge counts
      wait_clks(8);
      rd_cnt(H0, v16);                check("x4: 3 more edges = 23", v16, 16'd23);
      quad(0, 3, 1'b0, 3);            // back to 00
      quad(0, 20, 1'b0, 3);           // 5 cycles back
      wait_clks(8);
      rd_cnt(H0, v16);                check("x4: 5 cycles back = 0", v16, 16'd0);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("x4: DIR set after backward", v8 & S_DIR, S_DIR);
      check("x4: landing on 0 = CMP (reset) set MATCH", v8 & S_MATCH, S_MATCH);
      bus_wr(H0 | {4'h0, STAT}, S_MATCH);
      check("x4: pins back at 00", ui_in[1:0], 2'b00);
      // both inputs changing in one clock: ignored
      set_ab(0, 1, 1);
      wait_clks(8);
      set_ab(0, 0, 0);
      wait_clks(8);
      set_ab(0, 1, 0);                // a legal step, up
      wait_clks(8);
      set_ab(0, 0, 1);                // both change again: ignored
      wait_clks(8);
      rd_cnt(H0, v16);                check("x4: a step where both inputs change is ignored (1)", v16, 16'd1);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("x4: DIR still shows the last real step (up)", v8 & S_DIR, 8'h00);
      set_ab(0, 0, 0);                // 01 -> 00: a legal step up in x4
      wait_clks(8);
      rd_cnt(H0, v16);                check("x4: 01 -> 00 steps up (2)", v16, 16'd2);

      // -------------------------------------------------------- the other pairs
      bus_wr(H0 | {4'h0, CTRL}, M_PULSE | pins(1) | EN | CLR);
      pulses(1, 7, 3, 3);
      pulses(0, 3, 3, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("pair 1 (ui_in[3:2]) counts 7, pair 0 ignored", v16, 16'd7);
      bus_wr(H0 | {4'h0, CTRL}, M_PULSE | pins(2) | EN | CLR);
      pulses(2, 6, 3, 3);
      pulses(1, 3, 3, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("pair 2 (ui_in[5:4]) counts 6, pair 1 ignored", v16, 16'd6);
      bus_wr(H0 | {4'h0, CTRL}, M_PULSE | pins(3) | EN | CLR);
      pulses(3, 5, 3, 3);
      pulses(2, 3, 3, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("pair 3 (ui_in[7:6]) counts 5, pair 2 ignored", v16, 16'd5);
      bus_wr(H0 | {4'h0, CTRL}, M_X4 | pins(3) | EN | CLR);
      set_ab(3, 0, 0);
      wait_clks(8);
      quad(3, 12, 1'b1, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("pair 3 x4: 3 cycles = 12", v16, 16'd12);
      set_ab(3, 0, 0);
      wait_clks(8);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("pair 3: A/B readback 00", v8 & (S_A | S_B), 8'h00);
      set_ab(3, 1, 1);                // wait: through the synchroniser
      wait_clks(8);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("pair 3: A/B readback 11", v8 & (S_A | S_B), S_A | S_B);
      set_ab(3, 0, 0);
      wait_clks(8);

      // -------------------------------------------------------------- FILT
      bus_wr(H0 | {4'h0, CTRL}, M_PULSE | pins(0) | EN | FILT | CLR);
      bus_rd(H0 | {4'h0, CTRL}, v8);  check("FILT reads back", v8, M_PULSE | pins(0) | EN | FILT);
      pulses(0, 1, 2, 12);
      wait_clks(8);
      rd_cnt(H0, v16);                check("FILT: a 2-clock glitch is rejected", v16, 16'd0);
      pulses(0, 1, 3, 12);
      wait_clks(8);
      rd_cnt(H0, v16);                check("FILT: a 3-clock glitch is rejected", v16, 16'd0);
      pulses(0, 1, 5, 12);
      wait_clks(8);
      rd_cnt(H0, v16);                check("FILT: a 5-clock pulse counts", v16, 16'd1);
      pulses(0, 1, 4, 12);
      wait_clks(8);
      rd_cnt(H0, v16);                check("FILT: a 4-clock pulse counts (the limit)", v16, 16'd2);
      pulses(0, 3, 6, 6);
      wait_clks(8);
      rd_cnt(H0, v16);                check("FILT: 3 wide pulses count (5)", v16, 16'd5);
      // the filter is on B too: a glitch on B in x1 mode must not flip the direction
      bus_wr(H0 | {4'h0, CTRL}, M_X1 | pins(0) | EN | FILT);
      ui_in[1] = 1'b1;                // B glitch of 2 clocks, A's edge inside it
      @(negedge clk);
      ui_in[0] = 1'b1;
      @(negedge clk);
      ui_in[1] = 1'b0;
      wait_clks(6);
      ui_in[0] = 1'b0;
      wait_clks(12);
      rd_cnt(H0, v16);                check("FILT: a B glitch does not turn the step down (6)", v16, 16'd6);
      // without FILT the same 2-clock pulse counts
      bus_wr(H0 | {4'h0, CTRL}, M_PULSE | pins(0) | EN);
      pulses(0, 1, 2, 12);
      wait_clks(8);
      rd_cnt(H0, v16);                check("no FILT: the 2-clock pulse counts (7)", v16, 16'd7);

      // ------------------------------------------------- CNT latch / load
      bus_wr(H0 | {4'h0, CTRL}, M_PULSE | pins(0));         // EN off
      bus_wr(H0 | {4'h0, CNT_H}, 8'h12);
      rd_cnt(H0, v16);                check("CNT: a CNT_H write alone holds (7)", v16, 16'd7);
      bus_wr(H0 | {4'h0, CNT_L}, 8'h34);
      rd_cnt(H0, v16);                check("CNT: the CNT_L write loads {held H, L} = 0x1234", v16, 16'h1234);
      bus_rd(H0 | {4'h0, CNT_L}, v8); check("CNT_L reads 0x34", v8, 8'h34);
      wr16(H0, CNT_L, 16'hABCD);      // change the count without a CNT_L read
      bus_rd(H0 | {4'h0, CNT_H}, v8); check("CNT_H is the latched 0x12, not 0xAB", v8, 8'h12);
      bus_rd(H0 | {4'h0, CNT_L}, v8); check("CNT_L reads 0xCD", v8, 8'hCD);
      bus_rd(H0 | {4'h0, CNT_H}, v8); check("CNT_H now the latched 0xAB", v8, 8'hAB);
      // a load straddling a byte boundary, through the counter
      bus_wr(H0 | {4'h0, CTRL}, M_PULSE | pins(0) | EN);
      wr16(H0, CNT_L, 16'h00FE);
      pulses(0, 3, 3, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("CNT: 0x00FE + 3 = 0x0101 (the latch is consistent)", v16, 16'h0101);

      // ------------------------------------------------------- CMP / MATCH / GE
      bus_wr(H0 | {4'h0, CTRL}, M_DIR | pins(0) | EN | CLR);
      bus_wr(H0 | {4'h0, STAT}, 8'hFF);                     // a clean slate
      wr16(H0, CMP_L, 16'h0010);
      bus_rd(H0 | {4'h0, CMP_L}, v8); check("CMP_L reads back 0x10", v8, 8'h10);
      bus_rd(H0 | {4'h0, CMP_H}, v8); check("CMP_H reads back 0x00", v8, 8'h00);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("CMP: STAT all 0 at 0 < 16 (no GE, no MATCH)", v8, 8'h00);
      check("CMP: ge0 level 0", ge0, 1'b0);
      set_ab(0, 0, 0);
      pulses(0, 15, 3, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("CMP: 15 pulses -> 15", v16, 16'd15);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("CMP: at 15 MATCH 0, GE 0", v8 & (S_GE | S_MATCH), 8'h00);
      pulses(0, 1, 3, 3);
      wait_clks(8);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("CMP: at 16 MATCH 1, GE 1", v8 & (S_GE | S_MATCH), S_GE | S_MATCH);
      check("CMP: ge0 level 1", ge0, 1'b1);
      check("CMP: irq0 0 with IE 0", irq0, 1'b0);
      pulses(0, 2, 3, 3);
      wait_clks(8);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("CMP: at 18 MATCH sticky, GE 1", v8 & (S_GE | S_MATCH), S_GE | S_MATCH);
      bus_wr(H0 | {4'h0, STAT}, S_MATCH);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("CMP: W1C clears MATCH, GE stays", v8 & (S_GE | S_MATCH), S_GE);
      set_ab(0, 0, 1);                // down
      pulses(0, 2, 3, 3);             // 18 -> 16
      wait_clks(8);
      rd_cnt(H0, v16);                check("CMP: back down to 16", v16, 16'd16);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("CMP: reached from above sets MATCH again", v8 & S_MATCH, S_MATCH);
      bus_wr(H0 | {4'h0, STAT}, S_MATCH);
      wait_clks(20);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("CMP: MATCH sets once - cleared while at 16 it stays clear", v8 & S_MATCH, 8'h00);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("CMP: ... and on a second read", v8 & (S_GE | S_MATCH), S_GE);
      pulses(0, 1, 3, 3);             // 16 -> 15: GE falls
      wait_clks(8);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("CMP: at 15 GE 0, no MATCH", v8 & (S_GE | S_MATCH), 8'h00);
      check("CMP: ge0 level 0 again", ge0, 1'b0);
      // writing CMP equal to the count does not set MATCH (it is the step)
      wr16(H0, CMP_L, 16'd15);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("CMP: a CMP write that equals the count: GE 1, MATCH 0", v8 & (S_GE | S_MATCH), S_GE);

      // -------------------------------------------------------------- OVF
      wr16(H0, CMP_L, 16'h0010);
      bus_wr(H0 | {4'h0, CTRL}, M_PULSE | pins(0) | EN);
      set_ab(0, 0, 0);
      wr16(H0, CNT_L, 16'hFFFE);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("OVF: at 0xFFFE GE 1, flags 0", v8 & (S_GE | S_OVF | S_UNF | S_MATCH), S_GE);
      pulses(0, 1, 3, 3);
      wait_clks(8);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("OVF: 0xFFFF, no OVF yet", v8 & S_OVF, 8'h00);
      pulses(0, 1, 3, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("OVF: wrapped to 0", v16, 16'h0000);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("OVF: OVF set, GE 0, UNF 0, MATCH 0", v8 & (S_GE | S_OVF | S_UNF | S_MATCH), S_OVF);
      check("OVF: irq0 0 with IE 0", irq0, 1'b0);
      bus_wr(H0 | {4'h0, CTRL}, M_PULSE | pins(0) | EN | IE);
      check("OVF: irq0 follows IE", irq0, 1'b1);
      bus_wr(H0 | {4'h0, STAT}, S_MATCH | S_UNF);           // the wrong bits: no effect
      bus_rd(H0 | {4'h0, STAT}, v8);  check("OVF: W1C of other bits leaves OVF", v8 & S_OVF, S_OVF);
      check("OVF: irq0 still 1", irq0, 1'b1);
      bus_wr(H0 | {4'h0, STAT}, S_OVF);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("OVF: W1C clears OVF", v8 & S_OVF, 8'h00);
      check("OVF: irq0 0 after the clear", irq0, 1'b0);
      // a wrap that lands on CMP = 0 sets MATCH and OVF together
      wr16(H0, CMP_L, 16'h0000);
      wr16(H0, CNT_L, 16'hFFFF);
      pulses(0, 1, 3, 3);
      wait_clks(8);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("OVF: a wrap onto CMP 0 sets OVF and MATCH", v8 & (S_OVF | S_MATCH), S_OVF | S_MATCH);
      bus_wr(H0 | {4'h0, STAT}, S_OVF | S_MATCH);

      // -------------------------------------------------------------- UNF
      wr16(H0, CMP_L, 16'h0010);
      bus_wr(H0 | {4'h0, CTRL}, M_DIR | pins(0) | EN | IE | CLR);
      set_ab(0, 0, 1);                // down
      wait_clks(8);
      pulses(0, 1, 3, 3);
      wait_clks(8);
      rd_cnt(H0, v16);                check("UNF: 0 - 1 = 0xFFFF", v16, 16'hFFFF);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("UNF: UNF and DIR set, GE 1, OVF 0", v8 & (S_GE | S_OVF | S_UNF | S_DIR), S_GE | S_UNF | S_DIR);
      check("UNF: irq0 1 with IE", irq0, 1'b1);
      bus_wr(H0 | {4'h0, CTRL}, M_DIR | pins(0) | EN);       // IE off
      check("UNF: irq0 0 without IE, flag kept", irq0, 1'b0);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("UNF: flag still set", v8 & S_UNF, S_UNF);
      bus_wr(H0 | {4'h0, CTRL}, M_DIR | pins(0) | EN | IE);
      bus_wr(H0 | {4'h0, STAT}, S_UNF);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("UNF: W1C clears UNF", v8 & S_UNF, 8'h00);
      check("UNF: irq0 0 after the clear", irq0, 1'b0);
      set_ab(0, 0, 0);
      wait_clks(8);

      // -------------------------------------------------------------- irq
      // MATCH alone with IE
      bus_wr(H0 | {4'h0, CTRL}, M_PULSE | pins(0) | EN | IE | CLR);
      wr16(H0, CMP_L, 16'h0003);
      pulses(0, 3, 3, 3);
      wait_clks(8);
      check("irq: MATCH with IE raises irq0", irq0, 1'b1);
      check("irq: HSC1 quiet", irq1, 1'b0);
      bus_wr(H0 | {4'h0, STAT}, 8'hFF);                     // clear everything
      check("irq: cleared", irq0, 1'b0);
      bus_rd(H0 | {4'h0, STAT}, v8);  check("irq: STAT flags 0, GE 1 (3 >= 3)", v8, S_GE);

      // ------------------------------------------------- CLR with a count
      wr16(H0, CNT_L, 16'h5A5A);
      rd_cnt(H0, v16);                check("CLR: count loaded 0x5A5A", v16, 16'h5A5A);
      bus_wr(H0 | {4'h0, CTRL}, M_PULSE | pins(0) | EN | IE | CLR);
      rd_cnt(H0, v16);                check("CLR: count 0 again", v16, 16'h0000);
      bus_rd(H0 | {4'h0, CTRL}, v8);  check("CLR: CTRL reads without bit 6", v8, M_PULSE | pins(0) | EN | IE);

      // --------------------------------------- HSC1 at 0x68 on pair 1 (misc40)
      bus_wr(H1 | {4'h0, CTRL}, M_DIR | pins(1) | EN);
      bus_rd(H1 | {4'h0, CTRL}, v8);  check("HSC1: CTRL reads back", v8, M_DIR | pins(1) | EN);
      bus_rd(H0 | {4'h0, CTRL}, v8);  check("HSC1: HSC0's CTRL untouched", v8, M_PULSE | pins(0) | EN | IE);
      set_ab(1, 0, 0);
      pulses(1, 9, 3, 3);
      wait_clks(8);
      rd_cnt(H1, v16);                check("HSC1: 9 pulses up on ui_in[3:2]", v16, 16'd9);
      set_ab(1, 0, 1);
      pulses(1, 4, 3, 3);
      wait_clks(8);
      rd_cnt(H1, v16);                check("HSC1: 4 pulses down with ui_in[3] high (5)", v16, 16'd5);
      rd_cnt(H0, v16);                check("HSC1: HSC0's count untouched (0)", v16, 16'd0);
      wr16(H1, CMP_L, 16'h0005);
      bus_rd(H1 | {4'h0, STAT}, v8);  check("HSC1: GE 1 at 5 >= 5, DIR 1, B 1", v8 & (S_GE | S_DIR | S_B), S_GE | S_DIR | S_B);
      check("HSC1: ge1 level 1", ge1, 1'b1);
      set_ab(1, 0, 0);
      wait_clks(8);                   // B's fall through the synchroniser before x4 sees it
      bus_wr(H1 | {4'h0, CTRL}, M_X4 | pins(1) | EN | IE | CLR);
      quad(1, 8, 1'b1, 2);
      wait_clks(8);
      rd_cnt(H1, v16);                check("HSC1: x4 2 cycles = 8", v16, 16'd8);
      bus_rd(H1 | {4'h0, STAT}, v8);  check("HSC1: MATCH set passing 5, GE 1", v8 & (S_GE | S_MATCH), S_GE | S_MATCH);
      check("HSC1: irq1 1", irq1, 1'b1);
      check("HSC1: irq0 0", irq0, 1'b0);
      bus_wr(H1 | {4'h0, STAT}, S_MATCH);
      check("HSC1: irq1 cleared", irq1, 1'b0);

      // ---------------------------------------------------------------- done
      wait_clks(4);
      $display("%0d passed, %0d failed", n_pass, n_fail);
      if (n_fail == 0) $display("ALL PASSED");
      else             $display("SOME FAILED");
      $finish;
   end

   // a runaway guard
   initial
   begin
      #2_000_000;
      $display("FAIL  timeout");
      $display("SOME FAILED");
      $finish;
   end

endmodule
