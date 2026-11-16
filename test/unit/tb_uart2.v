`default_nettype none
`timescale 1ns / 1ps

/* tb_uart2: lisa_uart (the chip's UART2) with RESPIN 40's transmit FIFO,
   RS-485 DE and the receive idle timer, self-checking (make uart2, Icarus).

   The BRG is programmed through brg_wr / brg_d as the CPU does it (a bit
   is 32 x (brg_d + 1) clocks: brg_d 15 = 512 clocks for the FIFO fill,
   brg_d 0 = 32 clocks, the fastest, for the rest).  tx is decoded here;
   DE, tx_idle and idle_flag are timed against the frames on the wire and
   the receiver's byte strobe; a continuous checker holds tx_idle against
   the transmitter's own state (hierarchical peeks into the DUT). */

`define CHECK(cond, msg) \
   begin \
      checks = checks + 1; \
      if (cond) $display("PASS: %s", msg); \
      else begin fails = fails + 1; $display("FAIL: %s   (t=%0t)", msg, $time); end \
   end

module tb_uart2;

   reg         clk = 1'b0;
   always #10 clk = ~clk;                    // 50 MHz
   reg         rst_n = 1'b0;

   reg         rx = 1'b1;
   wire        tx;
   reg  [7:0]  tx_d = 8'h0;
   reg         tx_wr = 1'b0;
   reg         rx_rd = 1'b0;
   wire [7:0]  rx_d;
   wire        rx_data_avail;
   wire        tx_buf_empty;
   wire        rx_overrun;
   reg         brg_wr = 1'b0;
   reg  [7:0]  brg_d = 8'h0;
   reg  [7:0]  idle_thresh = 8'h0;
   reg         de_en = 1'b0;
   reg         de_pol = 1'b0;
   reg         idle_clr = 1'b0;
   wire        tx_idle;
   wire        de;
   wire        idle_flag;

   lisa_uart dut
   (
      .clk              ( clk           ),
      .rst_n            ( rst_n         ),
      .rst_async_n      ( rst_n         ),
      .rx               ( rx            ),
      .tx               ( tx            ),
      .tx_d             ( tx_d          ),
      .tx_wr            ( tx_wr         ),
      .rx_rd            ( rx_rd         ),
      .rx_d             ( rx_d          ),
      .rx_data_avail    ( rx_data_avail ),
      .tx_buf_empty     ( tx_buf_empty  ),
      .rx_overrun       ( rx_overrun    ),
      .brg_wr           ( brg_wr        ),
      .brg_d            ( brg_d         ),
      .autobaud_disable ( 1'b1          ),
      .idle_thresh      ( idle_thresh   ),
      .de_en            ( de_en         ),
      .de_pol           ( de_pol        ),
      .idle_clr         ( idle_clr      ),
      .tx_idle          ( tx_idle       ),
      .de               ( de            ),
      .idle_flag        ( idle_flag     )
   );

   // ------------------------------------------------------------------
   // Bookkeeping
   // ------------------------------------------------------------------
   integer     checks = 0;
   integer     fails = 0;
   integer     bitclks  = 416;               // clocks a bit (the BRG's reset default: 32 x 13)
   integer     edgeclks = 26;                // clocks between the 16 baud edges of a bit
   localparam  CLK = 20;                     // ns

   // the tx decoder
   integer     tx_n = 0;                     // frames decoded
   reg  [7:0]  tx_got[0:31];
   integer     stop_errs = 0;
   time        t_last_start = 0;             // the last start bit's falling edge on tx

   // the DE / tx_idle monitors
   integer     de_rises = 0, de_falls = 0;
   time        t_de_rise = 0, t_de_fall = 0;
   integer     txidle_rises = 0, txidle_falls = 0;
   time        t_txidle_rise = 0, t_txidle_fall = 0;

   // the receiver's byte strobe (the idle timer's restart)
   time        t_strobe = 0;
   time        t_rx_end = 0;                 // when the testbench finished the last stop bit
   reg  [7:0]  rx_sent[0:15];                // the bytes sent into rx, in order
   integer     rx_sent_n = 0;
   time        t_flag_set = 0;
   integer     flag_sets = 0;

   // tx_idle against the transmitter's state
   integer     inv_viol = 0;
   integer     inv_lag = 0;
   wire        tx8n_idle = dut.i_lisa_tx8n_2.mode == 2'd0 && dut.s_tx8n_empty && dut.tx_fifo_empty;

   reg  [7:0]  pattern[0:9];
   reg  [7:0]  rxpat[0:7];
   reg  [7:0]  got;
   integer     i, n, ok;
   time        t_q;

   // ------------------------------------------------------------------
   // Monitors
   // ------------------------------------------------------------------
   // Decode tx: sample the middle of each bit from the start bit's fall
   // (the transmitter's start bit is 17/16 of a bit; the samples stay
   // inside their bits).
   always
   begin : tx_decoder
      reg [7:0] b;
      integer k;
      @(negedge tx);
      t_last_start = $time;
      repeat (bitclks + bitclks / 2) @(posedge clk);
      for (k = 0; k < 8; k = k + 1)
      begin
         b[k] = tx;
         repeat (bitclks) @(posedge clk);
      end
      if (tx !== 1'b1)
         stop_errs = stop_errs + 1;
      tx_got[tx_n] = b;
      tx_n = tx_n + 1;
   end

   always @(posedge de)        begin de_rises = de_rises + 1;         t_de_rise = $time;     end
   always @(negedge de)        begin de_falls = de_falls + 1;         t_de_fall = $time;     end
   always @(posedge tx_idle)   begin txidle_rises = txidle_rises + 1; t_txidle_rise = $time; end
   always @(negedge tx_idle)   begin txidle_falls = txidle_falls + 1; t_txidle_fall = $time; end
   always @(posedge idle_flag) begin flag_sets = flag_sets + 1;       t_flag_set = $time;    end

   always @(negedge clk)
      if (dut.s_rx_strobe)
         t_strobe = $time - CLK / 2;         // the posedge it was set

   // tx_idle may never be 1 while the transmitter works or the FIFO holds
   // a byte, and must follow the transmitter's idle state within a baud
   // edge interval (the stop bit on the wire ends one edge after the
   // transmitter's state machine returns to idle)
   always @(negedge clk)
      if (rst_n)
      begin
         if (tx_idle && !tx8n_idle)
            inv_viol = inv_viol + 1;
         if (tx8n_idle && !tx_idle)
         begin
            inv_lag = inv_lag + 1;
            if (inv_lag > edgeclks + 1)
               inv_viol = inv_viol + 1;
         end
         else
            inv_lag = 0;
      end

   // ------------------------------------------------------------------
   // Stimulus helpers: inputs change on the falling clock edge
   // ------------------------------------------------------------------
   task tick(input integer m);
   begin
      repeat (m) @(negedge clk);
   end
   endtask

   // the CPU's BRG write: a bit of 32 x (d + 1) clocks
   task set_brg(input [7:0] d);
   begin
      @(negedge clk); brg_d = d; brg_wr = 1'b1;
      @(negedge clk); brg_wr = 1'b0;
      bitclks  = 32 * (d + 1);
      edgeclks = 2 * (d + 1);
      tick(2 * bitclks);                     // the generator's accumulator settles on the new period
   end
   endtask

   // the CPU's write of 0x12: the strobe a clock wide, a clock between
   // writes (two clocks a byte)
   task cpu_write(input [7:0] b);
   begin
      @(negedge clk); tx_d = b; tx_wr = 1'b1;
      @(negedge clk); tx_wr = 1'b0;
   end
   endtask

   // a byte into rx at the programmed rate
   task send_rx(input [7:0] b);
      integer k;
   begin
      @(negedge clk); rx = 1'b0;
      tick(bitclks);
      for (k = 0; k < 8; k = k + 1)
      begin
         rx = b[k];
         tick(bitclks);
      end
      rx = 1'b1;
      tick(bitclks);
      t_rx_end = $time;
      rx_sent[rx_sent_n] = b;
      rx_sent_n = rx_sent_n + 1;
   end
   endtask

   // the CPU's read of 0x12
   task rx_read(output [7:0] b);
   begin
      @(negedge clk); b = rx_d; rx_rd = 1'b1;
      @(negedge clk); rx_rd = 1'b0;
   end
   endtask

   task pulse_idle_clr;
   begin
      @(negedge clk); idle_clr = 1'b1;
      @(negedge clk); idle_clr = 1'b0;
   end
   endtask

   task wait_tx_idle;                        // bounded
      integer k;
   begin
      k = 0;
      while (!tx_idle && k < 200000)
      begin
         @(negedge clk);
         k = k + 1;
      end
   end
   endtask

   task wait_flag;                           // bounded
      integer k;
   begin
      k = 0;
      while (!idle_flag && k < 20000)
      begin
         @(negedge clk);
         k = k + 1;
      end
   end
   endtask

   task mon_reset;
   begin
      de_rises = 0; de_falls = 0; txidle_rises = 0; txidle_falls = 0;
      flag_sets = 0; stop_errs = 0;
   end
   endtask

   // the burst of cnt bytes from pattern[first..], one DE assertion: its
   // rise with the first byte's write, its fall at the end of the last
   // stop bit
   task tx_burst_checks(input integer cnt, input integer first, input active);
   begin
      wait_tx_idle;
      tick(bitclks * 12);                    // room for a byte that should not come
      `CHECK(tx_n == cnt, "the burst's bytes were all transmitted, no more")
      ok = 1;
      for (i = 0; i < cnt; i = i + 1)
         if (tx_got[i] !== pattern[first + i]) ok = 0;
      `CHECK(ok, "the bytes came out in the order written")
      `CHECK(stop_errs == 0, "every frame's stop bit was high")
      if (active)
      begin
         `CHECK(de_rises == 1 && de_falls == 1, "DE was asserted once for the burst")
         `CHECK(t_de_rise == t_q + CLK / 2, "DE rose at the clock the first byte was queued")
         `CHECK(t_de_fall == t_last_start + 161 * edgeclks * CLK, "DE fell at the end of the last stop bit (161 baud edges after its start bit)")
      end
      else
      begin
         `CHECK(de_falls == 1 && de_rises == 1, "DE (active low) was asserted once for the burst")
         `CHECK(t_de_fall == t_q + CLK / 2, "DE (active low) fell at the clock the first byte was queued")
         `CHECK(t_de_rise == t_last_start + 161 * edgeclks * CLK, "DE (active low) rose at the end of the last stop bit")
      end
      `CHECK(txidle_falls == 1 && txidle_rises == 1, "tx_idle dropped once and returned once")
      `CHECK(t_txidle_fall == t_q + CLK / 2, "tx_idle dropped at the clock the first byte was queued")
      `CHECK(t_txidle_rise == t_last_start + 161 * edgeclks * CLK, "tx_idle returned at the end of the last stop bit")
   end
   endtask

   // ------------------------------------------------------------------
   // The test
   // ------------------------------------------------------------------
   initial
   begin
      if ($test$plusargs("VCD"))
      begin
         $dumpfile("tb_uart2.vcd");
         $dumpvars(0, tb_uart2);
      end

      pattern[0] = 8'h55; pattern[1] = 8'hAA; pattern[2] = 8'h00; pattern[3] = 8'hFF;
      pattern[4] = 8'h01; pattern[5] = 8'h80; pattern[6] = 8'h3C; pattern[7] = 8'hC3;
      pattern[8] = 8'h5A; pattern[9] = 8'hA5;

      tick(3);
      rst_n = 1'b1;
      tick(5);
      `CHECK(tx_buf_empty === 1'b1 && tx_idle === 1'b1 && de === 1'b0 && idle_flag === 1'b0 && rx_data_avail === 1'b0,
             "reset: FIFO has room, transmitter idle, DE inactive, idle_flag clear, nothing received")

      // ---------------------------------------------------------------
      // A. The transmit FIFO at a slow rate (brg_d 15: 512 clocks a bit),
      //    ten writes two clocks apart: the first byte goes straight to
      //    the transmitter's buffer, writes 2-9 fill the FIFO, the tenth
      //    is dropped
      // ---------------------------------------------------------------
      $display("--- A: transmit FIFO, brg_d 15 ---");
      set_brg(8'd15);
      de_en = 1'b1; de_pol = 1'b0;
      tick(2);
      mon_reset;
      tx_n = 0;
      ok = 1;
      @(negedge clk); t_q = $time;           // the first write's strobe goes up here
      for (i = 0; i < 10; i = i + 1)
      begin
         tx_d = pattern[i]; tx_wr = 1'b1;
         @(negedge clk); tx_wr = 1'b0;       // the push happened on the posedge between
         if (i == 0)
            `CHECK(de === 1'b1 && tx_idle === 1'b0, "the first write: DE up and tx_idle down the clock after")
         if (i < 8 && tx_buf_empty !== 1'b1) ok = 0;
         if (i == 8)
            `CHECK(tx_buf_empty === 1'b0, "tx_buf_empty dropped on the ninth write (8 in the FIFO, 1 in the transmitter)")
         if (i == 9)
            `CHECK(tx_buf_empty === 1'b0, "the tenth write found it full")
         @(negedge clk);
      end
      `CHECK(ok, "tx_buf_empty stayed set through the first eight back-to-back writes")
      tx_burst_checks(9, 0, 1'b1);
      `CHECK(tx_buf_empty === 1'b1, "tx_buf_empty back after the burst")

      // ---------------------------------------------------------------
      // B. DE at the fastest rate (brg_d 0: 32 clocks a bit), both
      //    polarities, and disabled
      // ---------------------------------------------------------------
      $display("--- B: DE, brg_d 0 ---");
      set_brg(8'd0);

      // B1: active high
      mon_reset; tx_n = 0;
      @(negedge clk); t_q = $time;
      tx_d = pattern[0]; tx_wr = 1'b1;
      @(negedge clk); tx_wr = 1'b0;
      cpu_write(pattern[1]);
      cpu_write(pattern[2]);
      tx_burst_checks(3, 0, 1'b1);

      // B2: active low
      de_pol = 1'b1;
      tick(2);
      `CHECK(de === 1'b1, "DE idles high with de_pol set")
      mon_reset; tx_n = 0;
      @(negedge clk); t_q = $time;
      tx_d = pattern[3]; tx_wr = 1'b1;
      @(negedge clk); tx_wr = 1'b0;
      cpu_write(pattern[4]);
      cpu_write(pattern[5]);
      tx_burst_checks(3, 3, 1'b0);
      `CHECK(de === 1'b1, "DE back to its inactive (high) level")

      // B3: de_en clear, both polarities: DE holds the inactive level
      de_en = 1'b0; de_pol = 1'b0;
      tick(2);
      mon_reset; tx_n = 0;
      cpu_write(pattern[6]);
      cpu_write(pattern[7]);
      wait_tx_idle;
      tick(bitclks * 2);
      `CHECK(de_rises == 0 && de_falls == 0 && de === 1'b0, "de_en clear, de_pol 0: DE stayed low through a transmission")
      `CHECK(txidle_falls == 1 && txidle_rises == 1 && tx_n == 2, "... and tx_idle still tracked it")
      de_pol = 1'b1;
      tick(2);
      mon_reset; tx_n = 0;
      cpu_write(pattern[8]);
      wait_tx_idle;
      tick(bitclks * 2);
      `CHECK(de_rises == 0 && de_falls == 0 && de === 1'b1, "de_en clear, de_pol 1: DE stayed high through a transmission")
      de_pol = 1'b0;

      // ---------------------------------------------------------------
      // C. The idle timer (brg_d 0), threshold 10 bit times
      // ---------------------------------------------------------------
      $display("--- C: idle timer, brg_d 0 ---");
      rxpat[0] = 8'h55; rxpat[1] = 8'hAA; rxpat[2] = 8'h0F; rxpat[3] = 8'h81;
      rxpat[4] = 8'h7E; rxpat[5] = 8'h33; rxpat[6] = 8'h00; rxpat[7] = 8'hFF;
      mon_reset;
      @(negedge clk); idle_thresh = 8'd10;
      // two bytes back to back, then silence
      send_rx(rxpat[0]);
      send_rx(rxpat[1]);
      `CHECK(idle_flag === 1'b0 && flag_sets == 0, "two bytes back to back: no flag through them")
      tick(bitclks * 8);
      `CHECK(idle_flag === 1'b0, "not set 8 bit times after the last stop bit (threshold 10)")
      wait_flag;
      `CHECK(idle_flag === 1'b1, "set during the silence")
      `CHECK($time - t_rx_end <= 10 * bitclks * CLK, "... within 10 bit times of the last stop bit's end")
      `CHECK(t_flag_set >= t_strobe + 10 * bitclks * CLK - CLK && t_flag_set <= t_strobe + 10 * bitclks * CLK + 2 * CLK,
             "... exactly 10 bit times (160 baud edges) after the receiver completed the byte")
      `CHECK(flag_sets == 1, "set once")
      tick(bitclks * 25);
      `CHECK(idle_flag === 1'b1 && flag_sets == 1, "sticky: still set 25 bit times later, not set again")

      // a new byte does not clear it
      send_rx(rxpat[2]);
      `CHECK(idle_flag === 1'b1, "a new byte did not clear it")
      tick(bitclks * 12);
      `CHECK(idle_flag === 1'b1, "... nor its silence")

      // idle_clr clears it; the silence that already set it does not set it again
      pulse_idle_clr;
      `CHECK(idle_flag === 1'b0, "idle_clr cleared it")
      tick(bitclks * 25);
      `CHECK(idle_flag === 1'b0, "the same silence period did not set it again (the counter stopped at the threshold)")

      // a gap shorter than the threshold between two bytes does not set it
      mon_reset;
      send_rx(rxpat[3]);
      tick(bitclks * 5);
      `CHECK(idle_flag === 1'b0, "a 5 bit-time gap (threshold 10): not set")
      send_rx(rxpat[4]);
      tick(bitclks * 8);
      `CHECK(idle_flag === 1'b0 && flag_sets == 0, "... and the second byte restarted the count: not set 8 bit times after it")
      wait_flag;
      `CHECK(idle_flag === 1'b1 && $time - t_rx_end <= 10 * bitclks * CLK, "... set 10 bit times after the second byte")

      // the two extremes of a byte: 0x00 (9 bit times low) and 0xFF (9 bit
      // times high after the start bit) do not reach a threshold of 10 by
      // themselves (the completed byte restarts the count)
      pulse_idle_clr;
      mon_reset;
      send_rx(rxpat[6]);
      send_rx(rxpat[7]);
      tick(bitclks * 8);
      `CHECK(idle_flag === 1'b0 && flag_sets == 0, "0x00 then 0xFF: the runs inside a byte do not reach threshold 10")
      wait_flag;
      `CHECK(idle_flag === 1'b1, "... the silence after them does")

      // threshold 0: off
      pulse_idle_clr;
      mon_reset;
      @(negedge clk); idle_thresh = 8'd0;
      send_rx(rxpat[5]);
      tick(bitclks * 40);
      `CHECK(idle_flag === 1'b0 && flag_sets == 0, "threshold 0: never set, 40 bit times of silence")

      // raising the threshold during a silence: the count resumes and
      // the flag sets that many bit times later (within the prescaler's phase)
      @(negedge clk); idle_thresh = 8'd3; t_q = $time;
      tick(bitclks + bitclks / 2);
      `CHECK(idle_flag === 1'b0, "threshold raised to 3 in the silence: not set 1.5 bit times later")
      tick(bitclks * 2);
      `CHECK(idle_flag === 1'b1 && t_flag_set > t_q + 2 * bitclks * CLK, "... set between 2 and 3.5 bit times later")
      pulse_idle_clr;

      // ---------------------------------------------------------------
      // D. The receive path delivered everything, in order
      // ---------------------------------------------------------------
      $display("--- D: receive path ---");
      `CHECK(rx_data_avail === 1'b1 && rx_overrun === 1'b0, "bytes waiting, no overrun (8 sent, FIFO of 8)")
      ok = 1; n = 0;
      while (rx_data_avail && n < 16)
      begin
         rx_read(got);
         if (got !== rx_sent[n]) ok = 0;
         n = n + 1;
      end
      `CHECK(n == 8 && rx_sent_n == 8 && ok, "the eight bytes sent were read back in order")
      `CHECK(rx_data_avail === 1'b0, "FIFO empty after the reads")

      // ---------------------------------------------------------------
      `CHECK(inv_viol == 0, "tx_idle agreed with the transmitter's state throughout")

      $display("");
      $display("%0d checks, %0d failed", checks, fails);
      if (fails == 0)
         $display("ALL PASSED");
      else
         $display("SOME FAILED");
      $finish;
   end

   // the watchdog
   initial
   begin
      #20_000_000;
      $display("TIMEOUT");
      $display("SOME FAILED");
      $finish;
   end

endmodule
