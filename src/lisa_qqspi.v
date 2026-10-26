/*
 *  kianv harris RISCV project
 *
 *  copyright (c) 2022 hirosh dabui <hirosh@dabui.de>
 *
 *  permission to use, copy, modify, and/or distribute this software for any
 *  purpose with or without fee is hereby granted, provided that the above
 *  copyright notice and this permission notice appear in all copies.
 *
 *  the software is provided "as is" and the author disclaims all warranties
 *  with regard to this software including all implied warranties of
 *  merchantability and fitness. in no event shall the author be liable for
 *  any special, direct, indirect, or consequential damages or any damages
 *  whatsoever resulting from loss of use, data or profits, whether in an
 *  action of contract, negligence or other tortious action, arising out of
 *  or in connection with the use or performance of this software.
 *
 */
/*
  re-implementation and extension of from https://github.com/machdyne/qqspi/blob/main/rtl/qqspi.v
  Copyright (c) 2021 Lone Dynamics Corporation. All rights reserved.
*/
// added wmask, sync-comb fsm, spi flash support, cen polarity, faster during
// write operations: sb, sh behaves likes 8Mx32 memory
//
// Modified 3/21/2024 by Ken Pettit for 16-bit LISA instruction / data access.
//

`default_nettype none
module lisa_qqspi
#(
   parameter CHIP_SELECTS = 2
 )
(
   /* verilator lint_off UNUSEDSIGNAL */
   input  wire [23:0]               addr,       // 8Mx32
   /* verilator lint_on UNUSEDSIGNAL */
   output reg  [15:0]               rdata,      // Read data
   input  wire [15:0]               wdata,      // Data to write
   input  wire [1:0]                wstrb,      // Which bytes in the 32-bits to write
   output reg                       ready,      // Next 32-bit value is ready
   input  wire                      ready_ack,  // ACK that next wdata is ready
   output reg                       xfer_done,  // Total xfer_len transfer is done
   input  wire                      valid,      // Indicates a valid request 
   input  wire [3:0]                xfer_len,   // Number of 32-bit words to transfer
   input  wire                      clk,
   input  wire                      rst_n,
   input  wire [CHIP_SELECTS-1:0]   addr_16b,
   input  wire [CHIP_SELECTS-1:0]   is_flash,
   input  wire [CHIP_SELECTS-1:0]   quad_mode,
                                   
   output wire                      sclk,
   input  wire                      sio0_si_mosi_i,
   input  wire                      sio1_so_miso_i,
   input  wire                      sio2_i,
   input  wire                      sio3_i,
   
   output wire                      sio0_si_mosi_o,
   output wire                      sio1_so_miso_o,
   output wire                      sio2_o,
   output wire                      sio3_o,
   
   output reg [3:0]                 sio_oe,
   input wire [CHIP_SELECTS -1:0]   ce_ctrl,
   input wire [CHIP_SELECTS -1:0]   spi_mode,
   input wire [CHIP_SELECTS -1:0]   spi_rd_late,  // RESPIN 34: capture read data on SCLK's falling edge
   input wire [CHIP_SELECTS -1:0]   ddr_sel,      // RESPIN 37: DDR (EDh) instruction reads on this flash
   input wire                       ddr_seamless, // ... SDR instruction bursts through the capture pipeline
   input wire [2:0]                 ddr_cap,      // ... the capture point: cap + 1 half clocks after the edge
   input wire [3:0]                 ddr_dummy,    // ... EDh's dummy clocks after the mode byte (7)
   output reg [CHIP_SELECTS -1:0]   ce,
   input wire [CHIP_SELECTS*4-1:0]  dummy_read_cycles,
   input wire [3:0]                 spi_clk_div,
   input wire [6:0]                 spi_ce_delay,

   input wire                       custom_spi_cmd,
   input wire [7:0]                 cmd_quad_write,
   input wire                       stream      // A read burst that goes on, word after word, while
                                                // this is high: the client ends it by dropping it
);
//   localparam [7:0] CMD_QUAD_WRITE        = 8'h38;
   localparam [7:0] CMD_FAST_READ_QUAD    = 8'hEB;
   localparam [7:0] CMD_DTR_READ_QUAD     = 8'hED;
   localparam [7:0] CMD_WRITE             = 8'h02;
   localparam [7:0] CMD_READ              = 8'h03;
   localparam [3:0] S0_IDLE               = 4'd0;
   localparam [3:0] S1_SELECT_DEVICE      = 4'd1;
   localparam [3:0] S2_CMD                = 4'd2;
   localparam [3:0] S4_ADDR               = 4'd3;
   localparam [3:0] S5_WAIT               = 4'd4;
   localparam [3:0] S6_XFER               = 4'd5;
   localparam [3:0] S7_WAIT_FOR_XFER_DONE = 4'd6;
   localparam [3:0] S8_SELECT_WREN        = 4'd8;
   localparam [3:0] S9_SEND_WREN          = 4'd9;
   localparam [3:0] S10_DESELECT_WREN     = 4'd10;
   localparam [3:0] S11_WREN_WAIT         = 4'd11;
   localparam [3:0] S12_MODE              = 4'd12;   // a quad read's mode bits, driven 1
   localparam [3:0] S13_RUN               = 4'd13;   // RESPIN 37: a read's words through the capture pipeline
   
   reg  [3:0]                 sio_out;
   wire [3:0]                 sio_in;
   wire                       write;
   wire                       read;
   reg  [3:0]                 state, next_state;
   (* keep = "true" *)
   reg  [23:0]                spi_buf;
   reg  [4:0]                 xfer_cycles;
   reg                        is_quad;
   reg  [15:0]                rdata_next;
   reg                        sclk_next;
   reg  [3:0]                 sio_oe_next;
   reg  [3:0]                 sio_out_next;
   reg  [23:0]                spi_buf_next;
   reg                        is_quad_next;
   reg  [4:0]                 xfer_cycles_next;
   reg                        ready_next;
   reg                        xfer_done_next;
   reg  [CHIP_SELECTS -1:0]   ce_next;
   reg  [3:0]                 len_count;
   reg  [3:0]                 len_count_next;
   reg                        is_stream;        // This transfer is such a burst
   reg                        is_stream_next;
   reg                        late_pend;        // RESPIN 34: the last rising edge shifted a bit in
   reg                        late_pend_next;
   wire                       byte_offset;
   wire [4:0]                 wr_cycles;
   wire [15:0]                wr_buffer;
   wire                       addr_16b_c;
   wire                       quad_mode_c;
   wire                       is_flash_c;
   wire [3:0]                 dummy_read_cycles_c[CHIP_SELECTS-1:0];
   reg  [3:0]                 dummy_cycles;
   wire [7:0]                 custom_cmd_val;
   wire                       custom_cmd_addr;
   wire                       custom_cmd_read;
   wire                       spi_mode1;
   wire                       rd_late;
   reg  [3:0]                 clk_div_r;
   reg  [3:0]                 clk_div_next;
   reg  [6:0]                 ce_delay_r;
   // RESPIN 37: DDR reads and the capture pipeline
   reg                        dtr, dtr_next;    // this read is EDh: address, mode and data on both edges
   reg                        run, run_next;    // ... its words come through S13_RUN's capture pipeline
   reg                        sclk_r;           // SCLK (the pin but in a DDR read)
   reg                        sclk_n;           // SCLK half a clock late: a DDR read's pin
   reg  [3:0]                 sio_neg;          // the data lines at the falling edge of clk
   reg  [3:0]                 cap_pipe, cap_pipe_next;   // [k]: an edge launched a nibble k + 1 clocks ago
   reg  [1:0]                 nib_cnt, nib_cnt_next;     // nibbles of the word in spi_buf[15:0]
   reg                        word_full, word_full_next; // ... all four, waiting for ready to be free
   reg  [3:0]                 inflight, inflight_next;   // nibbles launched, not yet in rdata
   reg                        issue;            // this clock's SCLK edge launches a nibble
   wire                       ddr_c;
   wire                       run_c;
   wire                       dtr_tx;
   wire                       issue_ok;
   wire                       take;
   wire [3:0]                 nib;
   wire [15:0]                word;

   assign write = |wstrb;
   assign read = ~write;
   assign {sio3_o, sio2_o, sio1_so_miso_o, sio0_si_mosi_o} = sio_out;
   assign sio_in = {sio3_i, sio2_i, sio1_so_miso_i, sio0_si_mosi_i};
   assign addr_16b_c = |(ce_ctrl & addr_16b);
   assign is_flash_c = |(ce_ctrl & is_flash);
   assign quad_mode_c = |(ce_ctrl & quad_mode);
   assign spi_mode1   = |(ce_ctrl & spi_mode );
   // RESPIN 34: a read bit is shifted in on SCLK's rising edge as always,
   // and with rd_late taken again from the pins on the falling edge that
   // follows - nearly a whole SCLK period after the device changed it (on
   // the previous falling edge) instead of half of one, for clk/2 and the
   // round trip through the pads, the board and the part's clock-to-output
   // time; what goes out still shifts on the rising edge (spi_mode moves
   // both, which at clk/2 changes the outgoing bit on the edge the part
   // samples it).  late_pend says the bottom bits are the ones the last
   // rising edge shifted in: a phase that ends on a rising edge has the next
   // one's command or address loaded while SCLK is still high, and that
   // falling edge must not overwrite it.  The bits re-taken in a command,
   // address or write phase are the bottom ones nothing sends; the last
   // bit's falling edge is the clock S7 runs, so S7 takes it there.
   assign rd_late     = |(ce_ctrl & spi_rd_late) & !spi_mode1;
   assign custom_cmd_val = write ? wdata[7:0] : cmd_quad_write;
   assign custom_cmd_addr = wdata[8];
   assign custom_cmd_read = custom_spi_cmd && !write;

   // RESPIN 37.  A read of a flash select with its 0x17 DDR bit, a burst or a
   // single word (the debugger's), is a DTR Fast Read Quad I/O (EDh, the
   // W25Q128JV-DTR): the instruction on IO0 as before, then the address and
   // the mode byte a nibble on each SCLK edge, ddr_dummy dummy clocks, and
   // the data a nibble on each edge.  The address and mode go out with SCLK
   // half a clock late (sclk_n), so each nibble is on the lines half a clock
   // either side of the edge that takes it.  The data comes in through a
   // pipeline instead of the shift register: every edge that launches a
   // nibble (each edge in DDR, the falling ones in SDR) is marked in
   // cap_pipe, and the nibble is taken ddr_cap + 1 half clocks after the
   // clock that made the edge (an even ddr_cap from sio_neg, the lines at
   // clk's falling edge) - set by the host from the board's round trip.  In
   // a burst the edges keep going while there is room: a word to rdata as
   // its fourth nibble comes in, and the next word's edges already running,
   // so a word takes 4 clocks at clk/2 (8 in SDR) instead of 10.
   // ddr_seamless puts SDR bursts (EBh) through the same pipeline.  Every
   // other read and every write is as before; with the bits clear nothing
   // here is used.
   assign ddr_c    = |(ce_ctrl & ddr_sel) && is_flash_c && quad_mode_c && read && !custom_spi_cmd &&
                     !spi_mode1 && (is_stream || len_count == 4'h0);
   assign run_c    = ddr_c || (ddr_seamless && is_stream && is_flash_c && quad_mode_c && read &&
                     !custom_spi_cmd && !spi_mode1);
   assign dtr_tx   = dtr && is_quad;
   assign issue_ok = is_stream ? (inflight < 4'd4 || (inflight < 4'd8 && !ready)) : (inflight < 4'd8);
   assign take     = (state == S13_RUN) && cap_pipe[ddr_cap[2:1]];
   assign nib      = ddr_cap[0] ? sio_in : sio_neg;
   assign word     = {spi_buf[11:0], nib};
   assign sclk     = dtr ? sclk_n : sclk_r;

   always @(negedge clk)
   begin
      if (!rst_n)
         sclk_n  <= 1'b0;
      else
         sclk_n  <= sclk_r;
      sio_neg <= sio_in;
   end

   /*
   ================================================================
   Logic to create the dummy_cycles selection based on ce_ctrl
   ================================================================
   */
   generate
   for (genvar c = 0; c < CHIP_SELECTS; c = c + 1)
      begin : GEN_DUMMY
         assign dummy_read_cycles_c[c] = dummy_read_cycles[(c+1)*4-1 -: 4];
      end
   endgenerate
   
   integer i;
   always @*
   begin
      dummy_cycles = 4'h0;
      for (i = 0; i < CHIP_SELECTS; i = i + 1)
      begin
         dummy_cycles = dummy_cycles | (dummy_read_cycles_c[i] & {4{ce_ctrl[i]}});
      end
   end

   align_wdata align_wdata_i (
      .wstrb      (wstrb),
      .wdata      (wdata),
      .byte_offset(byte_offset),
      .wr_cycles  (wr_cycles),
      .wr_buffer  (wr_buffer)
   );

   // ======================================================================
   // CE delay counter
   // ======================================================================
   always @(posedge clk)
   begin
      if (!rst_n)
         ce_delay_r <= 7'h0;
      else
      begin
         if (ce != {CHIP_SELECTS{1'b1}})
            ce_delay_r <= spi_ce_delay;
         else if (ce_delay_r != 0)
            ce_delay_r <= ce_delay_r - 7'h1;
      end
   end

   always @(posedge clk) begin
      if (!rst_n) begin
         ce           <= ~0;
         sclk_r         <= 1'b0;
         sio_oe       <= 4'b0000;
         sio_out      <= 4'b0000;
         spi_buf      <= 0;
         is_quad      <= 0;
         xfer_cycles  <= 0;
         ready        <= 0;
         state        <= S0_IDLE;
         len_count    <= 4'h0;
         xfer_done    <= 1'b0;
         clk_div_r    <= 4'h0;
         is_stream    <= 1'b0;
         late_pend    <= 1'b0;
         dtr          <= 1'b0;
         run          <= 1'b0;
         cap_pipe     <= 4'h0;
         nib_cnt      <= 2'h0;
         word_full    <= 1'b0;
         inflight     <= 4'h0;
      end else begin
         state         <= next_state;
         ce            <= ce_next;
         sclk_r          <= sclk_next;
         sio_oe        <= sio_oe_next;
         sio_out       <= sio_out_next;
         spi_buf       <= spi_buf_next;
         is_quad       <= is_quad_next;
         xfer_cycles   <= xfer_cycles_next;
         rdata         <= rdata_next;
         ready         <= ready_next;
         len_count     <= len_count_next;
         is_stream     <= is_stream_next;
         late_pend     <= late_pend_next;
         xfer_done     <= xfer_done_next;
         clk_div_r     <= clk_div_next;
         dtr           <= dtr_next;
         run           <= run_next;
         cap_pipe      <= cap_pipe_next;
         nib_cnt       <= nib_cnt_next;
         word_full     <= word_full_next;
         inflight      <= inflight_next;
      end
   end
 
   always @(*) begin
      next_state       = state;
      ce_next          = ce;
      sclk_next        = sclk_r;
      sio_oe_next      = sio_oe;
      sio_out_next     = sio_out;
      spi_buf_next     = spi_buf;
      is_quad_next     = is_quad;
      xfer_cycles_next = xfer_cycles;
      ready_next       = ready;
      rdata_next       = rdata;
      xfer_cycles_next = xfer_cycles;
      len_count_next   = len_count;
      is_stream_next   = is_stream;
      late_pend_next   = 1'b0;
      xfer_done_next   = xfer_done;
      clk_div_next     = clk_div_r;
      dtr_next         = dtr;
      run_next         = run;
      nib_cnt_next     = nib_cnt;
      word_full_next   = word_full;
      inflight_next    = inflight;
      issue            = 1'b0;
      
      if (is_stream && !stream && state != S0_IDLE)
      begin
         // The client ended its burst (a jump, or the bus is wanted): deselect
         // now, whatever was in flight, and report the transfer done
         next_state       = S0_IDLE;
         ce_next          = ~0;
         sclk_next        = 1'b0;
         sio_oe_next      = 4'b0001;
         xfer_cycles_next = 0;
         ready_next       = 1'b0;
         xfer_done_next   = 1'b1;
         is_stream_next   = 1'b0;
         dtr_next         = 1'b0;
         run_next         = 1'b0;
         nib_cnt_next     = 2'h0;
         word_full_next   = 1'b0;
         inflight_next    = 4'h0;
      end
      else if (|xfer_cycles)
      begin  
         sio_out_next[3:0] = is_quad ? spi_buf[23:20] : {3'b0, spi_buf[23]};
         
         if (dtr_tx)
         begin
            // a DDR read's address and mode: a nibble out on each edge
            if (clk_div_r == 4'h0)
            begin
               clk_div_next = spi_clk_div;
               sclk_next = ~sclk_r;
               spi_buf_next = {spi_buf[19:0], 4'h0};
               xfer_cycles_next = xfer_cycles - 5'd4;
            end
            else
               clk_div_next = clk_div_r - 4'h1;
         end
         else if (sclk_r)
         begin
            if (clk_div_r == 4'h0)
            begin
               sclk_next = 1'b0;
               clk_div_next = spi_clk_div;
               if (rd_late && late_pend)
               begin
                  if (is_quad)
                     spi_buf_next[3:0] = sio_in[3:0];
                  else
                     spi_buf_next[0] = sio_in[1];
               end
               if (spi_mode1)
               begin
                  spi_buf_next = is_quad ? {spi_buf[19:0], sio_in[3:0]} : {spi_buf[22:0], sio_in[1]};
                  xfer_cycles_next = is_quad ? xfer_cycles - 4 : xfer_cycles - 1;
               end
            end
            else
            begin
               clk_div_next = clk_div_r - 4'h1;
               late_pend_next = late_pend;
            end
         end else begin
            if (clk_div_r == 4'h0)
            begin
               clk_div_next = spi_clk_div;
               sclk_next = 1'b1;
               if (!spi_mode1)
               begin
                  spi_buf_next = is_quad ? {spi_buf[19:0], sio_in[3:0]} : {spi_buf[22:0], sio_in[1]};
                  xfer_cycles_next = is_quad ? xfer_cycles - 4 : xfer_cycles - 1;
                  late_pend_next = 1'b1;
               end
            end
            else
               clk_div_next = clk_div_r - 4'h1;
         end
      end
      else
      begin
         case (state)
            S0_IDLE: begin
               sio_oe_next  = 4'b0001;
               is_quad_next = 0;
               is_stream_next = 0;
               dtr_next     = 1'b0;
               run_next     = 1'b0;
               xfer_done_next = 1'b0;
               if (valid && !ready) begin
                  next_state = write & is_flash_c ? S8_SELECT_WREN : S1_SELECT_DEVICE;
                  xfer_cycles_next = 0;
                  is_stream_next = stream & read;
               end else if (!valid && ready) begin
                  ready_next = 1'b0;
                  ce_next = ~0;
               end else begin
                  ce_next = ~0;
               end
            end
          
            S1_SELECT_DEVICE: begin
               if (ce_delay_r == 7'h0)
               begin
                  ce_next        = ~ce_ctrl;
                  next_state     = S2_CMD;
                  len_count_next = xfer_len;
               end
            end
          
            S8_SELECT_WREN: begin
               ce_next        = ~ce_ctrl;
               next_state     = S9_SEND_WREN;
            end
          
            S2_CMD: begin
               dtr_next = ddr_c;
               run_next = run_c;
               if (quad_mode_c) begin
                  spi_buf_next[23:16] = custom_spi_cmd ? custom_cmd_val : write ?
                     cmd_quad_write : ddr_c ? CMD_DTR_READ_QUAD : CMD_FAST_READ_QUAD;
               end else begin
                  spi_buf_next[23:16] = custom_spi_cmd ? custom_cmd_val : write ? CMD_WRITE : CMD_READ;
               end
           
               sio_out_next[3:0] = is_quad ? spi_buf_next[23:20] : {3'b0, spi_buf_next[23]};
               xfer_cycles_next = 8;
               next_state = ~custom_spi_cmd ? S4_ADDR : custom_cmd_addr ? S4_ADDR :
                            custom_cmd_read ? S6_XFER : S7_WAIT_FOR_XFER_DONE;
            end
          
            S4_ADDR: begin
               if (addr_16b_c)
                  spi_buf_next[23:8] = {addr[15:1], write ? byte_offset : 1'b0};
               else
                  spi_buf_next = {addr[23:1], write ? byte_offset : 1'b0};
              
               sio_oe_next = quad_mode_c ? 4'b1111 : 4'b0001;
               xfer_cycles_next = addr_16b_c ? 16 : 24;
              
               is_quad_next = quad_mode_c;
               if (dtr)
                  sclk_next = 1'b0;    // the falling edge after the instruction: a DTR part takes no address on it
               next_state = custom_spi_cmd ? S7_WAIT_FOR_XFER_DONE: quad_mode_c && read ?
                              (is_flash_c ? S12_MODE : S5_WAIT) : S6_XFER;
            end

            // A quad read (EB) continues with the dummy clocks, of which a
            // flash samples the first two as its mode bits M7-0: M5:4 = 1,0
            // puts a W25Q (0xA5 a Macronix part) into continuous-read mode,
            // where every later command is misread.  TT07 floated the bus
            // here, so the mode byte was whatever the lines did (on the Arty
            // it failed; the chip has no pull-ups either).  On a flash
            // select, drive all four lines 1 for those two clocks - 0xFF is
            // nothing to any part - and float the rest, which the dummy
            // count includes (6 = 2 + 4 for the W25Q128JV); a RAM has no
            // mode bits and gets all its wait cycles floating, as before
            // (tinyQV does the same, driving 0xA to live in continuous-read
            // mode and skipping the state for its PSRAMs).  RESPIN item 21,
            // 2026-10-18.
            S12_MODE: begin
               spi_buf_next[23:16] = 8'hff;
               sio_oe_next = 4'b1111;
               is_quad_next = 1'b1;
               xfer_cycles_next = 5'd8;
               next_state = S5_WAIT;
            end

            S5_WAIT: begin
               sio_oe_next = 4'b0000;
               xfer_cycles_next = dtr ? {1'h0, ddr_dummy} : !is_flash_c ? {1'h0, dummy_cycles} :
                                  dummy_cycles > 4'd2 ? {1'h0, dummy_cycles - 4'd2} : 5'd0;
               is_quad_next = 0;
               next_state = run ? S13_RUN : S6_XFER;
               nib_cnt_next   = 2'h0;
               word_full_next = 1'b0;
               inflight_next  = 4'h0;
               ready_next     = 1'b0;
            end

            // RESPIN 37: the data through the capture pipeline (above).  A
            // single word goes to S7 as the shift register's would; a burst
            // runs here until the client drops stream (the abort above).
            S13_RUN: begin
               sio_oe_next = 4'b0000;
               if (clk_div_r != 4'h0)
                  clk_div_next = clk_div_r - 4'h1;
               else if ((!dtr && !sclk_r) || issue_ok)
               begin
                  clk_div_next = spi_clk_div;
                  sclk_next    = ~sclk_r;
                  issue        = dtr || sclk_r;
               end

               if (ready && ready_ack)
                  ready_next = 1'b0;
               if (take)
               begin
                  spi_buf_next[15:0] = word;
                  nib_cnt_next = nib_cnt + 2'h1;
               end
               if (take && nib_cnt == 2'h3)
               begin
                  if (!is_stream)
                     next_state = S7_WAIT_FOR_XFER_DONE;
                  else if (!ready)
                  begin
                     rdata_next = {word[7:0], word[15:8]};
                     ready_next = 1'b1;
                  end
                  else
                     word_full_next = 1'b1;
               end
               else if (word_full && !ready)
               begin
                  rdata_next = {spi_buf[7:0], spi_buf[15:8]};
                  ready_next = 1'b1;
                  word_full_next = 1'b0;
               end
               inflight_next = inflight + {3'h0, issue} -
                               ((is_stream && ((take && nib_cnt == 2'h3 && !ready) || (word_full && !ready))) ?
                                4'd4 : 4'd0);
            end
          
            S6_XFER: begin
               is_quad_next = quad_mode_c;
               ready_next = 1'b0;
               
               if (write) begin
                 sio_oe_next  = quad_mode_c ? 4'b1111 : 4'b0001;
                 spi_buf_next[23:8] = wr_buffer;
                 // the word's first bit on the pins now (RESPIN 34): after
                 // S7 SCLK is low, and the transfer's first clock is its
                 // rising edge - at clk/2 the bit changed on the edge the
                 // part samples it (the Arty's PSRAM took a mix of it and
                 // the last bit of the word before)
                 sio_out_next[3:0] = quad_mode_c ? wr_buffer[15:12] : {3'b0, wr_buffer[15]};
               end else begin
                 sio_oe_next = quad_mode_c ? 4'b0000 : 4'b0001;
               end
               
               xfer_cycles_next = write ? wr_cycles : 16;
               next_state = S7_WAIT_FOR_XFER_DONE;
            end
          
            S7_WAIT_FOR_XFER_DONE: begin
               // transform from little to big endian; with rd_late the last
               // bit's falling edge is now (late_pend from its rising edge):
               // the buffer takes it (S7 rebuilds rdata every clock it waits)
               if (rd_late && late_pend)
               begin
                  if (is_quad)
                     spi_buf_next[3:0] = sio_in[3:0];
                  else
                     spi_buf_next[0] = sio_in[1];
               end
               rdata_next = {spi_buf_next[7:0], spi_buf_next[15:8]};
               ready_next = 1'b1;
               sclk_next = 1'b0;
               if (is_stream)
               begin
                  // A burst: the next word when the client has room for it (ready
                  // stays high until then); it ends the burst by dropping stream
                  if (ready_ack)
                     next_state = S6_XFER;
               end
               else if (len_count == 4'h0)
               begin
                  next_state     = S0_IDLE;
                  xfer_done_next = 1'b1;
               end

               // Wait for ready_ack to ensure new data
               // is available
               else if (ready_ack || !write)
               begin
                  next_state     = S6_XFER;
                  len_count_next = len_count - 4'h1;
               end
            end

            S9_SEND_WREN: begin
               spi_buf_next[23:16] = 8'h06;
               sio_out_next[3:0] = {3'b0, spi_buf_next[23]};
               xfer_cycles_next = 8;
               next_state = S10_DESELECT_WREN;
            end

            S10_DESELECT_WREN: begin
               ce_next        = ~0;
               sclk_next      = 1'b0;
               next_state     = S11_WREN_WAIT;
            end
          
            S11_WREN_WAIT: begin
               next_state     = S1_SELECT_DEVICE;
            end
          
          
            default: next_state = S0_IDLE;
         endcase
      end

      // the edges that launched a nibble, a clock older at each stage (S13_RUN only)
      cap_pipe_next = (state == S13_RUN) ? {cap_pipe[2:0], issue} : 4'h0;
   end
endmodule

module align_wdata
(
   input  wire [ 1:0] wstrb,
   input  wire [15:0] wdata,
   output reg         byte_offset,
   output reg  [ 4:0] wr_cycles,
   output reg  [15:0] wr_buffer
);

   always @(*) begin
      wr_buffer = 16'h0;
      case (wstrb)
         2'b01: begin
            byte_offset = 0;
            wr_buffer[15:8] = wdata[7:0];
            wr_cycles = 8;
         end
         2'b10: begin
            byte_offset = 1;
            wr_buffer[15:8] = wdata[15:8];
            wr_cycles = 8;
         end
         2'b11: begin
            byte_offset = 0;
            wr_buffer = {wdata[7:0], wdata[15:8]};
            wr_cycles = 16;
         end
         default: begin
            byte_offset = 0;
            wr_buffer   = {wdata[7:0], wdata[15:8]};
            wr_cycles   = 16;
         end
      endcase
   end
endmodule

// vim: et sw=3 ts=3
