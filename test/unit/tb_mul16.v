// tb_mul16.v: the 16 x 16 multiplier (src/lisa_mul16.v) on its own.  The
// bus is driven the way the core drives it: d_we / d_rd one clock, an
// access every few clocks (a random gap), d_o sampled in the strobe's
// clock.  The product is read after BUSY is polled clear and compared with
// the testbench's own `*`: random unsigned and signed pairs and the corner
// values, ACC as a dot product, CLR, the BUSY timing (4 clocks, P the old
// value before that), a restart and CLR while BUSY.  Self-checking: PASS /
// FAIL per group (a FAIL line per mismatch), then ALL PASSED or SOME FAILED.
//    make mul16   (iverilog -g2012)

`timescale 1ns/1ps

module tb_mul16;

   reg            clk = 1'b0;
   reg            rst_n = 1'b0;
   reg   [6:0]    d_addr = 7'h0;
   reg   [7:0]    d_i = 8'h0;
   reg            d_periph = 1'b0;
   reg            d_we = 1'b0;
   reg            d_rd = 1'b0;
   wire  [7:0]    d_o;

   integer        seed = 20261114;
   integer        n_groups_pass = 0;
   integer        n_groups_fail = 0;
   integer        g_err;               // mismatches in the current group
   integer        gap = 1;             // idle clocks after each access

   always #10 clk = ~clk;              // 50 MHz

   lisa_mul16 dut
   (
      .clk      ( clk      ),
      .rst_n    ( rst_n    ),
      .d_addr   ( d_addr   ),
      .d_i      ( d_i      ),
      .d_periph ( d_periph ),
      .d_we     ( d_we     ),
      .d_rd     ( d_rd     ),
      .d_o      ( d_o      )
   );

   // the registers
   localparam [6:0] A_L = 7'h70, A_H = 7'h71, B_L = 7'h72, B_H = 7'h73,
                    P0 = 7'h74, P1 = 7'h75, P2 = 7'h76, P3 = 7'h77,
                    CTRL = 7'h78;
   // CTRL bits
   localparam [7:0] SIGNED = 8'h01, ACC = 8'h02, CLR = 8'h04, BUSY = 8'h80;

   // ---------------------------------------------------------------- checks
   task group_begin;
      begin
         g_err = 0;
      end
   endtask

   task group_end(input string name);
      begin
         if (g_err == 0)
         begin
            n_groups_pass = n_groups_pass + 1;
            $display("PASS  %0s", name);
         end
         else
         begin
            n_groups_fail = n_groups_fail + 1;
            $display("FAIL  %0s: %0d mismatches", name, g_err);
         end
      end
   endtask

   task expect32(input string what, input [31:0] got, input [31:0] exp);
      begin
         if (got !== exp)
         begin
            g_err = g_err + 1;
            if (g_err <= 10)
               $display("   FAIL %0s: got 0x%08h, expected 0x%08h", what, got, exp);
         end
      end
   endtask

   // ---------------------------------------------------------------- the bus
   // Every task starts and ends at a falling edge of clk; the strobe is
   // sampled by the rising edge in between, then `gap` idle clocks.
   task bus_wr(input [6:0] addr, input [7:0] v);
      begin
         d_addr = addr; d_i = v; d_periph = 1'b1; d_we = 1'b1;
         @(negedge clk);
         d_periph = 1'b0; d_we = 1'b0; d_addr = 7'h0; d_i = 8'h0;
         repeat (gap) @(negedge clk);
      end
   endtask

   task bus_rd(input [6:0] addr, output [7:0] v);
      begin
         d_addr = addr; d_periph = 1'b1; d_rd = 1'b1;
         #8 v = d_o;                   // in the strobe's clock, before its edge
         @(negedge clk);
         d_periph = 1'b0; d_rd = 1'b0; d_addr = 7'h0;
         repeat (gap) @(negedge clk);
      end
   endtask

   // a look at a register without a bus cycle (the timing groups only):
   // d_o is combinational from the flops, so this is what a read in the
   // current clock would return
   task peek(input [6:0] addr, output [7:0] v);
      begin
         d_addr = addr;
         #1 v = d_o;
      end
   endtask

   task peek_p(output [31:0] v);
      reg [7:0] b0, b1, b2, b3;
      begin
         peek(P0, b0);
         peek(P1, b1);
         peek(P2, b2);
         peek(P3, b3);
         v = {b3, b2, b1, b0};
      end
   endtask

   task wait_clks(input integer n);
      begin
         repeat (n) @(negedge clk);
      end
   endtask

   // the operands as a program writes them: the B_H write starts
   task wr_ops(input [15:0] a, input [15:0] b);
      begin
         bus_wr(A_L, a[7:0]);
         bus_wr(A_H, a[15:8]);
         bus_wr(B_L, b[7:0]);
         bus_wr(B_H, b[15:8]);
      end
   endtask

   // poll CTRL until BUSY is clear
   task wait_idle;
      reg [7:0] c;
      integer   n;
      begin
         n = 0;
         c = BUSY;
         while (c[7] && n < 20)
         begin
            bus_rd(CTRL, c);
            n = n + 1;
         end
         if (c[7])
         begin
            g_err = g_err + 1;
            $display("   FAIL BUSY never cleared");
         end
      end
   endtask

   task rd_p(output [31:0] v);
      reg [7:0] b0, b1, b2, b3;
      begin
         bus_rd(P0, b0);
         bus_rd(P1, b1);
         bus_rd(P2, b2);
         bus_rd(P3, b3);
         v = {b3, b2, b1, b0};
      end
   endtask

   // one product: write, wait, read
   task mul(input [15:0] a, input [15:0] b, output [31:0] p);
      begin
         wr_ops(a, b);
         wait_idle;
         rd_p(p);
      end
   endtask

   // the references
   function [31:0] umul(input [15:0] a, input [15:0] b);
      begin
         umul = {16'h0, a} * {16'h0, b};
      end
   endfunction

   function [31:0] smul(input [15:0] a, input [15:0] b);
      begin
         smul = {{16{a[15]}}, a} * {{16{b[15]}}, b};
      end
   endfunction

   // a random 16-bit value, a corner value one time in eight
   function [15:0] rnd16(input dummy);
      reg [31:0] r;
      begin
         r = $random(seed);
         case (r[18:16])
         3'd0:    case (r[21:19])
                  3'd0:    rnd16 = 16'h0000;
                  3'd1:    rnd16 = 16'h0001;
                  3'd2:    rnd16 = 16'h7FFF;
                  3'd3:    rnd16 = 16'h8000;
                  3'd4:    rnd16 = 16'hFFFF;
                  3'd5:    rnd16 = 16'h8001;
                  3'd6:    rnd16 = 16'h00FF;
                  default: rnd16 = 16'hFF00;
                  endcase
         default: rnd16 = r[15:0];
         endcase
      end
   endfunction

   function integer rnd_gap(input dummy);
      reg [31:0] r;
      begin
         r = $random(seed);
         rnd_gap = r[1:0];             // 0..3 idle clocks
      end
   endfunction

   // ---------------------------------------------------------------- the test
   reg   [15:0]   a, b;
   reg   [31:0]   p, exp, acc_ref, old_p;
   reg   [7:0]    v;
   integer        i, k;
   string         s;

   initial
   begin
      if ($test$plusargs("VCD"))
      begin
         $dumpfile("tb_mul16.vcd");
         $dumpvars(0, tb_mul16);
      end
      if ($value$plusargs("SEED=%d", seed))   // vvp mul16.vvp +SEED=n
         $display("seed %0d", seed);

      wait_clks(3);
      rst_n = 1'b1;
      wait_clks(2);

      // ---------------------------------------------------- reset / readback
      group_begin;
      bus_rd(CTRL, v); expect32("CTRL after reset", v, 8'h00);
      rd_p(p);         expect32("P after reset", p, 32'h0);
      bus_wr(A_L, 8'h34); bus_wr(A_H, 8'h12); bus_wr(B_L, 8'h78);
      bus_rd(A_L, v);  expect32("A_L readback", v, 8'h34);
      bus_rd(A_H, v);  expect32("A_H readback", v, 8'h12);
      bus_rd(B_L, v);  expect32("B_L readback", v, 8'h78);
      bus_rd(7'h79, v); expect32("0x79 reads 0", v, 8'h00);
      bus_rd(7'h7F, v); expect32("0x7F reads 0", v, 8'h00);
      bus_rd(7'h6F, v); expect32("0x6F reads 0", v, 8'h00);
      bus_wr(CTRL, SIGNED | ACC);
      bus_rd(CTRL, v); expect32("CTRL SIGNED|ACC readback", v, SIGNED | ACC);
      bus_wr(CTRL, 8'hFF);             // only [1:0] are flops, CLR acts
      bus_rd(CTRL, v); expect32("CTRL unimplemented bits read 0", v, SIGNED | ACC);
      bus_wr(CTRL, 8'h00);
      bus_rd(CTRL, v); expect32("CTRL cleared", v, 8'h00);
      group_end("reset, operand readback, unowned addresses");

      // ---------------------------------------------------- unsigned corners
      group_begin;
      bus_wr(CTRL, 8'h00);
      mul(16'hFFFF, 16'hFFFF, p); expect32("u FFFF x FFFF", p, 32'hFFFE0001);
      mul(16'h8000, 16'h8000, p); expect32("u 8000 x 8000", p, 32'h40000000);
      mul(16'h0000, 16'hFFFF, p); expect32("u 0 x FFFF", p, 32'h0);
      mul(16'hFFFF, 16'h0000, p); expect32("u FFFF x 0", p, 32'h0);
      mul(16'h0001, 16'hFFFF, p); expect32("u 1 x FFFF", p, 32'h0000FFFF);
      mul(16'hFFFF, 16'h0001, p); expect32("u FFFF x 1", p, 32'h0000FFFF);
      mul(16'h1234, 16'h5678, p); expect32("u 1234 x 5678", p, 32'h06260060);
      mul(16'h8000, 16'hFFFF, p); expect32("u 8000 x FFFF", p, 32'h7FFF8000);
      mul(16'h0101, 16'h0101, p); expect32("u 0101 x 0101", p, 32'h00010201);
      group_end("unsigned corners");

      // ---------------------------------------------------- unsigned random
      group_begin;
      for (i = 0; i < 400; i = i + 1)
      begin
         a = rnd16(0); b = rnd16(0); gap = rnd_gap(0);
         mul(a, b, p);
         $sformat(s, "u %04h x %04h", a, b);
         expect32(s, p, umul(a, b));
      end
      gap = 1;
      group_end("unsigned random (400)");

      // ---------------------------------------------------- signed corners
      group_begin;
      bus_wr(CTRL, SIGNED);
      mul(16'h8000, 16'h8000, p); expect32("s 8000 x 8000", p, 32'h40000000);
      mul(16'hFFFF, 16'hFFFF, p); expect32("s FFFF x FFFF", p, 32'h00000001);
      mul(16'h0000, 16'h8000, p); expect32("s 0 x 8000", p, 32'h0);
      mul(16'h8000, 16'h0000, p); expect32("s 8000 x 0", p, 32'h0);
      mul(16'h0001, 16'h8000, p); expect32("s 1 x 8000", p, 32'hFFFF8000);
      mul(16'h8000, 16'h0001, p); expect32("s 8000 x 1", p, 32'hFFFF8000);
      mul(16'hFFFF, 16'h0001, p); expect32("s -1 x 1", p, 32'hFFFFFFFF);
      mul(16'h0001, 16'hFFFF, p); expect32("s 1 x -1", p, 32'hFFFFFFFF);
      mul(16'h8000, 16'hFFFF, p); expect32("s 8000 x -1", p, 32'h00008000);
      mul(16'hFFFF, 16'h8000, p); expect32("s -1 x 8000", p, 32'h00008000);
      mul(16'h7FFF, 16'h7FFF, p); expect32("s 7FFF x 7FFF", p, 32'h3FFF0001);
      mul(16'h7FFF, 16'h8000, p); expect32("s 7FFF x 8000", p, 32'hC0008000);
      mul(16'h8000, 16'h7FFF, p); expect32("s 8000 x 7FFF", p, 32'hC0008000);
      mul(16'hFFFE, 16'h0003, p); expect32("s -2 x 3", p, 32'hFFFFFFFA);
      mul(16'h0003, 16'hFFFE, p); expect32("s 3 x -2", p, 32'hFFFFFFFA);
      mul(16'hFFFE, 16'hFFFD, p); expect32("s -2 x -3", p, 32'h00000006);
      group_end("signed corners");

      // ---------------------------------------------------- signed random
      group_begin;
      for (i = 0; i < 400; i = i + 1)
      begin
         a = rnd16(0); b = rnd16(0); gap = rnd_gap(0);
         mul(a, b, p);
         $sformat(s, "s %04h x %04h", a, b);
         expect32(s, p, smul(a, b));
      end
      gap = 1;
      group_end("signed random (400)");

      // ---------------------------------------------------- ACC: a dot product
      group_begin;
      bus_wr(CTRL, SIGNED | ACC | CLR);
      rd_p(p); expect32("P after CLR", p, 32'h0);
      acc_ref = 32'h0;
      for (i = 0; i < 64; i = i + 1)
      begin
         a = rnd16(0); b = rnd16(0); gap = rnd_gap(0);
         acc_ref = acc_ref + smul(a, b);
         mul(a, b, p);
         $sformat(s, "acc s %04h x %04h (step %0d)", a, b, i);
         expect32(s, p, acc_ref);
      end
      gap = 1;
      // a sum that wraps negative then back
      bus_wr(CTRL, SIGNED | ACC | CLR);
      mul(16'h8000, 16'h7FFF, p); expect32("acc s 8000 x 7FFF", p, 32'hC0008000);
      mul(16'h8000, 16'h7FFF, p); expect32("acc s + 8000 x 7FFF", p, 32'h80010000);
      mul(16'h8000, 16'h8000, p); expect32("acc s + 8000 x 8000", p, 32'hC0010000);
      mul(16'h8000, 16'h8000, p); expect32("acc s + 8000 x 8000 again", p, 32'h00010000);
      mul(16'hFFFF, 16'h0001, p); expect32("acc s + -1", p, 32'h0000FFFF);
      group_end("ACC signed dot product (64 terms) and wrap");

      // ---------------------------------------------------- ACC unsigned, wrap at 2^32
      group_begin;
      bus_wr(CTRL, ACC | CLR);
      acc_ref = 32'h0;
      for (i = 0; i < 6; i = i + 1)
      begin
         acc_ref = acc_ref + 32'hFFFE0001;
         mul(16'hFFFF, 16'hFFFF, p);
         $sformat(s, "acc u FFFF x FFFF (step %0d)", i);
         expect32(s, p, acc_ref);
      end
      for (i = 0; i < 64; i = i + 1)
      begin
         a = rnd16(0); b = rnd16(0); gap = rnd_gap(0);
         acc_ref = acc_ref + umul(a, b);
         mul(a, b, p);
         $sformat(s, "acc u %04h x %04h (step %0d)", a, b, i);
         expect32(s, p, acc_ref);
      end
      gap = 1;
      group_end("ACC unsigned with wrap (70 terms)");

      // ---------------------------------------------------- CLR
      group_begin;
      bus_wr(CTRL, 8'h00);
      mul(16'h1234, 16'h5678, p); expect32("CLR: product first", p, 32'h06260060);
      bus_wr(CTRL, SIGNED | ACC | CLR);
      rd_p(p); expect32("CLR clears P", p, 32'h0);
      bus_rd(CTRL, v); expect32("CLR reads 0, mode kept", v, SIGNED | ACC);
      mul(16'h0002, 16'h0003, p); expect32("ACC from 0 after CLR", p, 32'h6);
      bus_wr(CTRL, CLR);               // CLR with the mode bits cleared
      rd_p(p); expect32("CLR again", p, 32'h0);
      bus_rd(CTRL, v); expect32("mode bits cleared with CLR", v, 8'h00);
      mul(16'hFFFF, 16'hFFFF, p); expect32("unsigned after CLR", p, 32'hFFFE0001);
      group_end("CLR");

      // ---------------------------------------------------- BUSY timing
      // The B_H write is clock 0: BUSY reads 1 and P the old value after
      // clocks 0-3, BUSY 0 and P the product after clock 4.
      group_begin;
      gap = 0;
      bus_wr(CTRL, 8'h00);
      mul(16'h1111, 16'h2222, p); expect32("timing: old product", p, 32'h02468642);
      old_p = p;
      bus_wr(A_L, 8'hCD); bus_wr(A_H, 8'hAB); bus_wr(B_L, 8'h21);
      exp = umul(16'hABCD, 16'h4321);
      bus_rd(CTRL, v); expect32("timing: not BUSY before", v, 8'h00);
      // bus_wr returns at the falling edge after the write's rising edge
      bus_wr(B_H, 8'h43);
      for (k = 1; k <= 4; k = k + 1)
      begin
         peek(CTRL, v);
         $sformat(s, "timing: BUSY after clock %0d", k - 1);
         expect32(s, v, BUSY);
         peek_p(p);
         $sformat(s, "timing: P old after clock %0d", k - 1);
         expect32(s, p, old_p);
         @(negedge clk);
      end
      peek(CTRL, v); expect32("timing: BUSY clear after clock 4", v, 8'h00);
      peek_p(p);  expect32("timing: P new after clock 4", p, exp);
      @(negedge clk);
      peek(CTRL, v); expect32("timing: still clear after clock 5", v, 8'h00);
      peek_p(p);  expect32("timing: P stays after clock 5", p, exp);
      d_addr = 7'h0;
      // signed and ACC take the same 4 clocks
      bus_wr(CTRL, SIGNED | ACC | CLR);
      bus_wr(A_L, 8'h00); bus_wr(A_H, 8'h80); bus_wr(B_L, 8'hFF);
      bus_wr(B_H, 8'hFF);
      for (k = 1; k <= 4; k = k + 1)
      begin
         peek(CTRL, v);
         $sformat(s, "timing s/acc: BUSY after clock %0d", k - 1);
         expect32(s, v, BUSY | SIGNED | ACC);
         peek_p(p);
         $sformat(s, "timing s/acc: P old after clock %0d", k - 1);
         expect32(s, p, 32'h0);
         @(negedge clk);
      end
      peek(CTRL, v); expect32("timing s/acc: clear after clock 4", v, SIGNED | ACC);
      peek_p(p);  expect32("timing s/acc: P after clock 4", p, 32'h00008000);
      d_addr = 7'h0;
      gap = 1;
      group_end("BUSY timing (4 clocks, P the old value before)");

      // ---------------------------------------------------- restart while BUSY
      group_begin;
      gap = 0;
      bus_wr(CTRL, 8'h00);
      bus_wr(A_L, 8'h55); bus_wr(A_H, 8'h55); bus_wr(B_L, 8'h33);
      bus_wr(B_H, 8'h33);              // 0x5555 x 0x3333, clock 0
      @(negedge clk);                  // clock 1
      bus_wr(B_H, 8'h77);              // restart at clock 2: 0x5555 x 0x7733
      for (k = 1; k <= 4; k = k + 1)
      begin
         peek(CTRL, v);
         $sformat(s, "restart: BUSY after restart clock %0d", k - 1);
         expect32(s, v, BUSY);
         @(negedge clk);
      end
      peek(CTRL, v); expect32("restart: clear 4 clocks after the restart", v, 8'h00);
      peek_p(p);  expect32("restart: the new operands' product", p, umul(16'h5555, 16'h7733));
      d_addr = 7'h0;
      // the restart written in the clock the previous product completes,
      // with ACC: both products land in P
      bus_wr(CTRL, SIGNED | ACC | CLR);
      bus_wr(A_L, 8'h10); bus_wr(A_H, 8'h00); bus_wr(B_L, 8'h00);
      bus_wr(B_H, 8'h01);              // 16 x 256 = 4096, clock 0
      wait_clks(3);                    // clocks 1-3
      bus_wr(B_H, 8'hFF);              // clock 4: 16 x -256 = -4096 restarts
      peek(CTRL, v); expect32("restart at completion: BUSY", v, BUSY | SIGNED | ACC);
      peek_p(p);  expect32("restart at completion: first product stored", p, 32'h00001000);
      wait_clks(4);
      peek(CTRL, v); expect32("restart at completion: clear", v, SIGNED | ACC);
      peek_p(p);  expect32("restart at completion: both accumulated", p, 32'h0);
      d_addr = 7'h0;
      // operands written while BUSY and B_H rewritten: the current operands
      bus_wr(CTRL, 8'h00);
      bus_wr(A_L, 8'hFF); bus_wr(A_H, 8'hFF); bus_wr(B_L, 8'hFF);
      bus_wr(B_H, 8'hFF);              // FFFF x FFFF
      bus_wr(A_L, 8'h02);              // A becomes FF02 mid-flight
      bus_wr(B_H, 8'h00);              // restart: FF02 x 00FF
      wait_idle;
      rd_p(p); expect32("restart after an operand write", p, umul(16'hFF02, 16'h00FF));
      gap = 1;
      group_end("restart while BUSY");

      // ---------------------------------------------------- CLR while BUSY
      group_begin;
      gap = 0;
      bus_wr(CTRL, ACC | CLR);
      mul(16'h0100, 16'h0100, p); expect32("clr-busy: P before", p, 32'h00010000);
      bus_wr(B_H, 8'h01);              // another 0x0100 x 0x0100 onto P, clock 0
      @(negedge clk);                  // clock 1
      bus_wr(CTRL, ACC | CLR);         // clock 2: CLR abandons it
      peek(CTRL, v); expect32("clr-busy: BUSY cleared by CLR", v, ACC);
      peek_p(p);  expect32("clr-busy: P cleared", p, 32'h0);
      wait_clks(5);
      peek_p(p);  expect32("clr-busy: nothing lands later", p, 32'h0);
      d_addr = 7'h0;
      gap = 1;
      mul(16'h0100, 16'h0100, p); expect32("clr-busy: a product after", p, 32'h00010000);
      group_end("CLR while BUSY abandons the multiply");

      // ---------------------------------------------------- the verdict
      $display("%0d groups passed, %0d failed", n_groups_pass, n_groups_fail);
      if (n_groups_fail == 0)
         $display("ALL PASSED");
      else
         $display("SOME FAILED");
      $finish;
   end

endmodule
