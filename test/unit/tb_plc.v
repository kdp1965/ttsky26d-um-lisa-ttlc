// tb_plc.v: the PLC timer / counter block (src/lisa_plc.v) on its own.
// The bus is driven the way the core drives it: d_we / d_rd one clock, an
// access every few clocks, d_o sampled in the strobe's clock; the TTLC's
// writes come as one-clock plc_we pulses, counter resets as cnt_rst levels.
// TC_PRE is set to 9 (a 1 ms tick every 10 clocks) so the run is short;
// the testbench watches the block's tick pulses (dut.tick) to count ticks.
// Self-checking: PASS / FAIL per check, then ALL PASSED or SOME FAILED.
//    make plc   (iverilog -g2012);  make plc VCD=1  for tb_plc.vcd
`timescale 1ns/1ps

module tb_plc;

   reg            clk = 1'b0;
   reg            rst_n = 1'b0;
   reg   [6:0]    d_addr = 7'h0;
   reg   [7:0]    d_i = 8'h0;
   reg            d_periph = 1'b0;
   reg            d_we = 1'b0;
   reg            d_rd = 1'b0;
   wire  [7:0]    d_o;
   reg            plc_we = 1'b0;
   reg   [3:0]    plc_addr = 4'h0;
   reg            plc_bit = 1'b0;
   reg   [7:0]    cnt_rst = 8'h0;
   wire  [7:0]    t_done, c_done;

   integer        n_pass = 0;
   integer        n_fail = 0;
   reg   [7:0]    v8;
   reg   [15:0]   v16;
   integer        n, p;

   always #10 clk = ~clk;              // 50 MHz

   lisa_plc dut
   (
      .clk      ( clk      ),
      .rst_n    ( rst_n    ),
      .d_addr   ( d_addr   ),
      .d_i      ( d_i      ),
      .d_periph ( d_periph ),
      .d_we     ( d_we     ),
      .d_rd     ( d_rd     ),
      .d_o      ( d_o      ),
      .plc_we   ( plc_we   ),
      .plc_addr ( plc_addr ),
      .plc_bit  ( plc_bit  ),
      .cnt_rst  ( cnt_rst  ),
      .t_done   ( t_done   ),
      .c_done   ( c_done   )
   );

   // the registers
   localparam [6:0] TC_IDX = 7'h50, TC_CTRL = 7'h51, TC_PRESET_L = 7'h52,
                    TC_PRESET_H = 7'h53, TC_VALUE_L = 7'h54, TC_VALUE_H = 7'h55,
                    T_DONE = 7'h56, C_DONE = 7'h57, TC_PRE_L = 7'h58, TC_PRE_H = 7'h59;
   // TC_CTRL bits
   localparam [7:0] TOF = 8'h01, DOWN = 8'h01, BASE1 = 8'h02, Q = 8'h08, IN = 8'h10,
                    LISA_IN = 8'h20, RST = 8'h40;
   // plc_addr of timer n / counter n
   localparam [3:0] T0 = 4'd0, T1 = 4'd1, T2 = 4'd2, T3 = 4'd3, T5 = 4'd5,
                    C0 = 4'd8, C1 = 4'd9, C2 = 4'd10, C3 = 4'd11;

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

   task check_range(input string name, input integer got, input integer lo, input integer hi);
      begin
         if (got >= lo && got <= hi)
         begin
            n_pass = n_pass + 1;
            $display("PASS  %0s (%0d)", name, got);
         end
         else
         begin
            n_fail = n_fail + 1;
            $display("FAIL  %0s: got %0d, expected %0d..%0d", name, got, lo, hi);
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
         #5 v = d_o;                   // sampled in the strobe's clock
         @(negedge clk);
         d_periph = 1'b0; d_rd = 1'b0; d_addr = 7'h0;
         repeat (2) @(negedge clk);
      end
   endtask

   task rd16(input [6:0] addr_l, input [6:0] addr_h, output [15:0] v);
      reg [7:0] l, h;
      begin
         bus_rd(addr_l, l);
         bus_rd(addr_h, h);
         v = {h, l};
      end
   endtask

   // the selected block's registers
   task setup(input [3:0] idx, input [7:0] ctrl, input [15:0] preset);
      begin
         bus_wr(TC_IDX, {4'h0, idx});
         bus_wr(TC_CTRL, ctrl);
         bus_wr(TC_PRESET_L, preset[7:0]);
         bus_wr(TC_PRESET_H, preset[15:8]);
      end
   endtask

   task rd_value(output [15:0] v);
      begin
         rd16(TC_VALUE_L, TC_VALUE_H, v);
      end
   endtask

   // ---------------------------------------------------------------- the TTLC
   // a one-clock write of bit b to I/O address 139 + a; returns right after
   // the clock the block took it (the callers settle, so the tick counting
   // of the timer tests stays exact)
   task ttlc_wr(input [3:0] a, input b);
      begin
         plc_we = 1'b1; plc_addr = a; plc_bit = b;
         @(negedge clk);
         plc_we = 1'b0;
      end
   endtask

   // n rising edges of the TTLC's bit (0, then 1, 0, 1, 0 ...: an edge every
   // two clocks whatever the bit was)
   task pulses(input [3:0] a, input integer n);
      integer i;
      begin
         plc_we = 1'b1; plc_addr = a; plc_bit = 1'b0;
         @(negedge clk);
         for (i = 0; i < n; i = i + 1)
         begin
            plc_we = 1'b1; plc_addr = a; plc_bit = 1'b1;
            @(negedge clk);
            plc_bit = 1'b0;
            @(negedge clk);
         end
         plc_we = 1'b0;
         repeat (2) @(negedge clk);    // the count and Q settle
      end
   endtask

   task settle;
      begin
         repeat (2) @(negedge clk);
      end
   endtask

   // ---------------------------------------------------------------- the ticks
   // returns at the falling edge after the clock that took the n-th tick of
   // base b (the timers' values are updated; Q one clock later)
   task wait_ticks(input [1:0] b, input integer n);
      integer i;
      begin
         i = 0;
         while (i < n)
         begin
            @(negedge clk);
            if (dut.tick[b]) i = i + 1;
         end
         @(negedge clk);
      end
   endtask

   // the clocks from one tick of base b to the next
   task tick_period(input [1:0] b, output integer per);
      begin
         @(negedge clk);
         while (!dut.tick[b]) @(negedge clk);
         per = 0;
         @(negedge clk);
         per = 1;
         while (!dut.tick[b])
         begin
            @(negedge clk);
            per = per + 1;
         end
      end
   endtask

   // ---------------------------------------------------------------- the test
   initial
   begin
      if ($test$plusargs("VCD"))
      begin
         $dumpfile("tb_plc.vcd");
         $dumpvars(0, tb_plc);
      end

      repeat (3) @(negedge clk);
      rst_n = 1'b1;
      repeat (2) @(negedge clk);

      // ---- reset values, unowned addresses
      $display("-- reset values");
      rd16(TC_PRE_L, TC_PRE_H, v16);      check("TC_PRE resets to 49999", v16, 16'hC34F);
      bus_rd(TC_IDX, v8);                 check("TC_IDX resets to 0", v8, 0);
      bus_rd(T_DONE, v8);                 check("T_DONE resets to 0", v8, 0);
      // an up counter's Q is count >= preset and the preset resets to 0: IEC's
      // CTU with PV 0 would have Q = 1, this block reads 0 until it is given a
      // preset
      bus_rd(C_DONE, v8);                 check("C_DONE resets to 0 (preset 0: a counter is off)", v8, 8'h00);
      bus_rd(TC_CTRL, v8);                check("TC_CTRL resets to 0", v8, 0);
      // the block decodes d_addr[3:0]; the group 0x50-0x5F is lisa_periph's
      // (t6x4-8), so only in-group unowned addresses read 0 here
      bus_rd(7'h5A, v8);                  check("0x5A reads 0", v8, 0);
      bus_rd(7'h5E, v8);                  check("0x5E reads 0", v8, 0);
      bus_rd(7'h5F, v8);                  check("0x5F reads 0", v8, 0);
      bus_wr(TC_IDX, 8'hFF);
      bus_rd(TC_IDX, v8);                 check("TC_IDX is 4 bits", v8, 8'h0F);

      // ---- the tick generator
      $display("-- the tick generator (TC_PRE 9)");
      bus_wr(TC_PRE_L, 8'd9);
      bus_wr(TC_PRE_H, 8'd0);
      rd16(TC_PRE_L, TC_PRE_H, v16);      check("TC_PRE readback", v16, 9);
      tick_period(0, p);                  check("1 ms tick every TC_PRE + 1 clocks", p, 10);
      tick_period(1, p);                  check("10 ms tick every 100 clocks", p, 100);
      tick_period(2, p);                  check("100 ms tick every 1000 clocks", p, 1000);
      tick_period(3, p);                  check("1 s tick every 10000 clocks", p, 10000);
      // a TC_PRE write restarts the prescaler: the first tick comes within
      // TC_PRE + 1 clocks of it however far the prescaler had got
      wait_ticks(0, 1);
      bus_wr(TC_PRE_L, 8'd4);
      bus_wr(TC_PRE_H, 8'd0);
      n = 0;
      while (!dut.tick[0] && n < 100)
      begin
         @(negedge clk);
         n = n + 1;
      end
      check_range("first tick within 6 clocks of a TC_PRE write", n, 1, 6);
      tick_period(0, p);                  check("tick period follows TC_PRE (5)", p, 5);
      bus_wr(TC_PRE_L, 8'd9);
      bus_wr(TC_PRE_H, 8'd0);
      tick_period(0, p);                  check("tick period back to 10", p, 10);

      // ---- timer 0: TON, base 0, preset 5
      $display("-- timer 0: TON base 0 preset 5");
      setup(T0, 8'h00, 16'd5);
      bus_rd(TC_IDX, v8);                 check("TC_IDX readback", v8, 0);
      bus_rd(TC_CTRL, v8);                check("timer CTRL readback (TON, base 0)", v8, 8'h00);
      rd16(TC_PRESET_L, TC_PRESET_H, v16); check("timer PRESET readback", v16, 5);
      rd_value(v16);                      check("timer VALUE 0 before IN", v16, 0);
      bus_rd(T_DONE, v8);                 check("T_DONE 0 before IN", v8, 0);
      wait_ticks(0, 1);                   // IN rises just after a tick: the counting is exact
      ttlc_wr(T0, 1'b1);
      settle;
      bus_rd(TC_CTRL, v8);                check("CTRL shows IN from the TTLC", v8, IN);
      wait_ticks(0, 3);
      rd_value(v16);                      check("TON VALUE 3 after 3 ticks", v16, 3);
      wait_ticks(0, 1);
      bus_rd(T_DONE, v8);                 check("TON Q still 0 after 4 ticks", v8, 8'h00);
      wait_ticks(0, 1);
      rd_value(v16);                      check("TON VALUE 5 after 5 ticks", v16, 5);
      bus_rd(T_DONE, v8);                 check("TON Q after 5 ticks", v8, 8'h01);
      bus_rd(TC_CTRL, v8);                check("CTRL shows Q and IN", v8, Q | IN);
      wait_ticks(0, 3);
      rd_value(v16);                      check("TON VALUE stops at the preset", v16, 5);
      bus_rd(T_DONE, v8);                 check("TON Q holds", v8, 8'h01);
      ttlc_wr(T0, 1'b0);
      settle;
      bus_rd(T_DONE, v8);                 check("TON Q falls at once with IN", v8, 8'h00);
      rd_value(v16);                      check("TON VALUE cleared by IN low", v16, 0);
      bus_rd(TC_CTRL, v8);                check("CTRL IN low", v8, 8'h00);
      // the same through the core's LISA_IN
      wait_ticks(0, 1);
      bus_wr(TC_CTRL, LISA_IN);
      bus_rd(TC_CTRL, v8);                check("CTRL shows LISA_IN and IN", v8, LISA_IN | IN);
      wait_ticks(0, 3);
      rd_value(v16);                      check("TON via LISA_IN: VALUE 3 after 3 ticks", v16, 3);
      wait_ticks(0, 1);
      bus_rd(T_DONE, v8);                 check("TON via LISA_IN: Q 0 after 4 ticks", v8, 8'h00);
      wait_ticks(0, 1);
      rd_value(v16);                      check("TON via LISA_IN: VALUE 5", v16, 5);
      bus_rd(T_DONE, v8);                 check("TON via LISA_IN: Q after 5 ticks", v8, 8'h01);
      bus_rd(TC_CTRL, v8);                check("CTRL shows LISA_IN, IN and Q", v8, LISA_IN | IN | Q);
      bus_wr(TC_CTRL, 8'h00);
      bus_rd(T_DONE, v8);                 check("TON Q falls with LISA_IN", v8, 8'h00);

      // ---- timer 1: TOF, base 0, preset 3
      $display("-- timer 1: TOF base 0 preset 3");
      setup(T1, TOF, 16'd3);
      bus_rd(TC_CTRL, v8);                check("timer CTRL readback (TOF)", v8, TOF);
      wait_ticks(0, 4);
      bus_rd(T_DONE, v8);                 check("TOF: no Q pulse at configuration", v8, 8'h00);
      rd_value(v16);                      check("TOF: VALUE 0 at configuration", v16, 0);
      wait_ticks(0, 1);
      ttlc_wr(T1, 1'b1);
      settle;
      bus_rd(T_DONE, v8);                 check("TOF Q at once with IN", v8, 8'h02);
      wait_ticks(0, 3);
      rd_value(v16);                      check("TOF VALUE 0 while IN", v16, 0);
      wait_ticks(0, 1);
      ttlc_wr(T1, 1'b0);
      wait_ticks(0, 2);
      bus_rd(T_DONE, v8);                 check("TOF Q holds 2 ticks after IN fell", v8, 8'h02);
      rd_value(v16);                      check("TOF VALUE 2", v16, 2);
      wait_ticks(0, 1);
      rd_value(v16);                      check("TOF VALUE 3 at the preset", v16, 3);
      bus_rd(T_DONE, v8);                 check("TOF Q falls 3 ticks after IN", v8, 8'h00);
      wait_ticks(0, 2);
      rd_value(v16);                      check("TOF VALUE holds the preset", v16, 3);
      bus_rd(T_DONE, v8);                 check("TOF Q stays 0", v8, 8'h00);
      ttlc_wr(T1, 1'b1);
      settle;
      bus_rd(T_DONE, v8);                 check("TOF retriggers: Q with IN", v8, 8'h02);
      rd_value(v16);                      check("TOF retriggers: VALUE 0", v16, 0);
      ttlc_wr(T1, 1'b0);
      wait_ticks(0, 4);
      bus_rd(T_DONE, v8);                 check("TOF Q 0 again after the delay", v8, 8'h00);

      // ---- timer 2: TON, base 1 (10 ms), preset 2
      $display("-- timer 2: TON base 1 preset 2");
      setup(T2, BASE1, 16'd2);
      bus_rd(TC_CTRL, v8);                check("timer CTRL readback (base 1)", v8, BASE1);
      wait_ticks(1, 1);
      ttlc_wr(T2, 1'b1);
      n = 0;
      while (!t_done[2] && n < 400)
      begin
         @(negedge clk);
         if (dut.tick[0]) n = n + 1;
      end
      check_range("TON base 1: Q after 11..20 1 ms ticks", n, 11, 20);
      rd_value(v16);                      check("TON base 1: VALUE 2", v16, 2);
      bus_rd(T_DONE, v8);                 check("T_DONE bit 2", v8, 8'h04);

      // ---- timer 3: the CTRL bits a timer ignores
      bus_wr(TC_IDX, 8'd3);
      bus_wr(TC_CTRL, 8'hC7);
      bus_rd(TC_CTRL, v8);                check("timer CTRL: bits 3, 4, 6, 7 not stored", v8, 8'h07);

      // ---- timer 5 (the top one): a preset of 0, Q follows IN
      setup(T5, LISA_IN, 16'd0);
      settle;
      bus_rd(T_DONE, v8);                 check("TON preset 0: Q follows IN (on)", v8, 8'h24);
      bus_wr(TC_CTRL, 8'h00);
      bus_rd(T_DONE, v8);                 check("TON preset 0: Q follows IN (off)", v8, 8'h04);

      // ---- the empty slots (6 + 4 of 8 + 8): timer 6 and counter 4 read 0 and take no write
      bus_wr(TC_IDX, 8'd6);
      bus_wr(TC_CTRL, LISA_IN);
      bus_wr(TC_PRESET_L, 8'hFF);
      bus_rd(TC_CTRL, v8);                check("timer slot 6 (empty): CTRL reads 0", v8, 0);
      bus_rd(TC_PRESET_L, v8);            check("timer slot 6 (empty): PRESET reads 0", v8, 0);
      bus_wr(TC_IDX, 8'd12);
      bus_wr(TC_PRESET_L, 8'hFF);
      bus_rd(TC_PRESET_L, v8);            check("counter slot 4 (empty): PRESET reads 0", v8, 0);

      // ---- counter 0: up, preset 3
      $display("-- counter 0: up preset 3");
      setup(C0, 8'h00, 16'd3);
      bus_rd(TC_IDX, v8);                 check("TC_IDX readback (8)", v8, 8);
      bus_rd(TC_CTRL, v8);                check("counter CTRL readback (up)", v8, 8'h00);
      rd16(TC_PRESET_L, TC_PRESET_H, v16); check("counter PRESET readback", v16, 3);
      bus_rd(C_DONE, v8);                 check("C_DONE: counter 0's Q 0 below its preset", v8, 8'h00);
      ttlc_wr(C0, 1'b1);
      settle;
      rd_value(v16);                      check("up: a rising edge counts", v16, 1);
      bus_rd(TC_CTRL, v8);                check("CTRL shows CU", v8, IN);
      ttlc_wr(C0, 1'b1);
      settle;
      rd_value(v16);                      check("up: a held level does not count", v16, 1);
      ttlc_wr(C0, 1'b0);
      settle;
      rd_value(v16);                      check("up: a falling edge does not count", v16, 1);
      ttlc_wr(C0, 1'b1);
      settle;
      rd_value(v16);                      check("up: count 2", v16, 2);
      bus_rd(C_DONE, v8);                 check("up: Q 0 below the preset", v8, 8'h00);
      pulses(C0, 1);
      rd_value(v16);                      check("up: count 3", v16, 3);
      bus_rd(C_DONE, v8);                 check("up: Q at the preset", v8, 8'h01);
      bus_rd(TC_CTRL, v8);                check("CTRL shows Q (CU low)", v8, Q);
      pulses(C0, 1);
      rd_value(v16);                      check("up: count 4", v16, 4);
      bus_rd(C_DONE, v8);                 check("up: Q above the preset", v8, 8'h01);
      // R from the storage bit
      cnt_rst[0] = 1'b1;
      settle;
      rd_value(v16);                      check("R clears the count", v16, 0);
      bus_rd(C_DONE, v8);                 check("R clears Q", v8, 8'h00);
      pulses(C0, 3);
      rd_value(v16);                      check("R held holds the count at 0", v16, 0);
      cnt_rst[0] = 1'b0;
      pulses(C0, 1);
      rd_value(v16);                      check("counts again after R", v16, 1);
      // the core's LISA_CU
      bus_wr(TC_CTRL, LISA_IN);
      rd_value(v16);                      check("LISA_CU rising edge counts", v16, 2);
      bus_wr(TC_CTRL, LISA_IN);
      rd_value(v16);                      check("LISA_CU held does not count", v16, 2);
      bus_rd(TC_CTRL, v8);                check("CTRL shows LISA_CU and CU", v8, LISA_IN | IN);
      bus_wr(TC_CTRL, 8'h00);
      bus_wr(TC_CTRL, LISA_IN);
      rd_value(v16);                      check("LISA_CU second edge", v16, 3);
      bus_rd(TC_CTRL, v8);                check("CTRL shows LISA_CU, CU and Q", v8, LISA_IN | IN | Q);
      // the RST write bit
      bus_wr(TC_CTRL, RST);
      rd_value(v16);                      check("RST write clears the count", v16, 0);
      bus_rd(C_DONE, v8);                 check("RST write clears Q", v8, 8'h00);
      bus_rd(TC_CTRL, v8);                check("RST reads 0", v8, 8'h00);
      // reading VALUE_L latches VALUE_H
      pulses(C0, 256);
      bus_rd(TC_VALUE_L, v8);             check("VALUE_L 0x00 at 0x0100", v8, 8'h00);
      pulses(C0, 256);
      bus_rd(TC_VALUE_H, v8);             check("VALUE_H latched by the L read", v8, 8'h01);
      rd_value(v16);                      check("VALUE 0x0200 after a new L read", v16, 16'h0200);
      // saturation
      pulses(C0, 65535 - 512 + 5);
      rd_value(v16);                      check("up saturates at 0xFFFF", v16, 16'hFFFF);
      bus_rd(C_DONE, v8);                 check("Q at 0xFFFF", v8, 8'h01);

      // ---- counter 1: down, preset 2
      $display("-- counter 1: down preset 2");
      setup(C1, DOWN, 16'd2);
      bus_rd(TC_CTRL, v8);                check("counter CTRL readback (down, Q at count 0)", v8, DOWN | Q);
      bus_rd(C_DONE, v8);                 check("down: Q at count 0 before a load", v8, 8'h03);
      cnt_rst[1] = 1'b1;
      settle;
      cnt_rst[1] = 1'b0;
      settle;
      rd_value(v16);                      check("down: R loads the preset", v16, 2);
      bus_rd(C_DONE, v8);                 check("down: Q 0 after the load", v8, 8'h01);
      pulses(C1, 1);
      rd_value(v16);                      check("down: count 1", v16, 1);
      bus_rd(C_DONE, v8);                 check("down: Q 0 at 1", v8, 8'h01);
      pulses(C1, 1);
      rd_value(v16);                      check("down: count 0", v16, 0);
      bus_rd(C_DONE, v8);                 check("down: Q at 0", v8, 8'h03);
      pulses(C1, 2);
      rd_value(v16);                      check("down saturates at 0", v16, 0);
      cnt_rst[1] = 1'b1;
      pulses(C1, 2);
      rd_value(v16);                      check("down: R held holds the preset", v16, 2);
      bus_rd(C_DONE, v8);                 check("down: Q 0 while R held", v8, 8'h01);
      cnt_rst[1] = 1'b0;
      pulses(C1, 1);
      rd_value(v16);                      check("down: counts again after R", v16, 1);
      bus_wr(TC_CTRL, DOWN | RST);
      rd_value(v16);                      check("down: RST write loads the preset", v16, 2);
      bus_rd(TC_CTRL, v8);                check("down: CTRL after RST write", v8, DOWN);

      // ---- counter 2: MODE and RST in one write, from up mode
      setup(C2, 8'h00, 16'd7);
      bus_wr(TC_CTRL, DOWN | RST);
      rd_value(v16);                      check("MODE down + RST in one write loads the preset", v16, 7);

      // ---- counter 3: the CTRL bits a counter ignores (0x8F: MODE and bits 1-3, 7)
      bus_wr(TC_IDX, 8'd11);
      bus_wr(TC_PRESET_L, 8'd5);
      bus_wr(TC_CTRL, 8'h8F);
      bus_rd(TC_CTRL, v8);                check("counter CTRL: bits 1, 2, 3, 4, 7 not stored", v8, DOWN | Q);

      // ---- the T_DONE / C_DONE bytes: timers 0 (LISA_IN, 5 ticks), 2 (IN
      // held) and 5 (preset 0, LISA_IN) on, 1 (TOF expired), 3 (TOF, IN never
      // high) and 4 (untouched) off, 6-7 no block; counters 0 (0xFFFF >= 3)
      // and 3 (down at 0) on, 1 and 2 (down, loaded) off, 4-7 no block
      $display("-- the done bytes");
      bus_wr(TC_IDX, 8'd0);
      bus_wr(TC_CTRL, LISA_IN);
      bus_wr(TC_IDX, 8'd5);
      bus_wr(TC_CTRL, LISA_IN);
      wait_ticks(0, 6);
      bus_rd(T_DONE, v8);                 check("T_DONE byte", v8, 8'h25);
      bus_rd(C_DONE, v8);                 check("C_DONE byte", v8, 8'h09);
      check("t_done port", t_done, 8'h25);
      check("c_done port", c_done, 8'h09);

      $display("");
      $display("%0d passed, %0d failed", n_pass, n_fail);
      if (n_fail == 0)
         $display("ALL PASSED");
      else
         $display("SOME FAILED");
      $finish;
   end

   // a watchdog
   initial
   begin
      #20_000_000;
      $display("TIMEOUT");
      $display("SOME FAILED");
      $finish;
   end

endmodule
