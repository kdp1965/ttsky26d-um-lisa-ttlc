/*
==============================================================================
lisa_uart.v:  Little ISA (LISA) dedicated UART (not shared with debug).

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

RESPIN 40 (the Modbus RTU additions, 2026-11-14):

 * An 8-byte transmit FIFO in front of the transmitter's one-byte buffer.
   tx_buf_empty now means "the FIFO has room" (0x13 [1], the bit a polling
   putc waits on); a write while it is full is dropped.  tx_idle (0x13
   [4]) is the FIFO empty and the transmitter through the stop bit of its
   last byte.
 * RS-485 direction: de is asserted from the clock a byte is queued into
   an idle transmitter until tx_idle is back (so it covers the last stop
   bit); the active level is high, or low with de_pol; with de_en clear
   de is the inactive level.
 * The idle timer: a counter of bit times of receive silence (restarted
   by any transition of the synchronized rx and by every byte the
   receiver completes); when it reaches idle_thresh (0x16, in bit times;
   0 disables it) idle_flag (0x13 [5]) is set and stays set until idle_clr
   (0x17 [2] written 1).  The counter stops at the threshold, so a silence
   period sets the flag once.
*/

module lisa_uart
(
   input  wire          clk,
   input  wire          rst_n,
   input  wire          rst_async_n,

   // UART signals
   input  wire          rx,
   output wire          tx,

   // UART
   input  wire [7:0]    tx_d,
   input  wire          tx_wr,
   input  wire          rx_rd,
   output wire [7:0]    rx_d,
   output wire          rx_data_avail,
   output wire          tx_buf_empty,        // the transmit FIFO has room (a write while full is dropped)
   output wire          rx_overrun,          // a byte arrived with the receive FIFO full (sticky until it is read empty)
   input  wire          brg_wr,
   input  wire [7:0]    brg_d,
   input  wire          autobaud_disable,

   // RESPIN 40: Modbus RTU
   input  wire [7:0]    idle_thresh,         // 0x16 UART2_IDLE: bit times of silence; 0 = off
   input  wire          de_en,               // 0x17 [0]: drive DE
   input  wire          de_pol,              // 0x17 [1]: 1 = DE active low
   input  wire          idle_clr,            // a one-clock pulse: clear idle_flag
   output wire          tx_idle,             // the FIFO empty and the transmitter idle
   output wire          de,                  // RS-485 direction, already polarity-applied; with de_en clear it is the inactive level
   output wire          idle_flag            // sticky: idle_thresh bit times of receive silence seen since the last receive activity
);

   reg   [1:0] s_rx_pipe;
   wire        s_baud_ref;
   wire        s_brg_wr;
   wire [13:0] s_brg_d;                      // the bit period in clocks
   wire        s_auto_brg_wr;
   wire [13:0] s_auto_brg_d;
//   wire  [1:0] rx_sel;

   // The baud reference's rising edges, 16 a bit: the tick the receiver
   // and the transmitter count on, detected the way they do it (so the
   // logic below is in lockstep with them)
   reg         s_baud_edge_r;
   wire        s_baud_edge = s_baud_ref & ~s_baud_edge_r;

   // The transmit FIFO
   reg   [7:0] tx_fifo[0:7];
   reg   [3:0] tx_wr_ptr;
   reg   [3:0] tx_rd_ptr;
   wire        tx_fifo_empty = tx_wr_ptr == tx_rd_ptr;
   wire        tx_fifo_full  = (tx_wr_ptr[2:0] == tx_rd_ptr[2:0]) && (tx_wr_ptr[3] != tx_rd_ptr[3]);
   reg         s_tx_wr_last;                 // tx_wr a clock ago: its rising edge queues the byte
   wire        tx_push = tx_wr & ~s_tx_wr_last & ~tx_fifo_full;
   wire        s_tx8n_empty;                 // the transmitter's one-byte buffer is free
   wire        tx_pop  = ~tx_fifo_empty & s_tx8n_empty;   // the handoff: one clock (the buffer is full the next)

   // The transmit path's occupancy, one flop so that tx_idle and DE (a
   // pin) cannot glitch: s_tx_act from the clock a byte is queued until
   // the stop bit of the last byte has ended with nothing waiting in the
   // FIFO or the transmitter's buffer.  lisa_tx8n shows only its buffer
   // and txd, so the frame's end is timed here from the start bit's fall
   // on tx: the start bit is 17 baud edges on the line (the transmitter's
   // first SEND_START edge does not advance its clock count), the data
   // bits 16 each and the stop bit 16, so the stop bit ends 161 edges
   // after the fall - one edge after the transmitter's own return to its
   // idle state, which is when txd is 1 for the stop bit's 16th
   // sixteenth.  A fall of tx while no frame is being counted is a start
   // bit (falls inside a frame are data).
   reg         s_tx_act;
   reg   [7:0] s_tx_frame;                   // baud edges since the start bit, stops at 161
   reg         s_tx_last;                    // tx a clock ago
   wire        s_tx_frame_idle = s_tx_frame == 8'd161;
   wire        s_tx_start = s_tx_last & ~tx & s_tx_frame_idle;
   wire        s_tx_done  = s_baud_edge & (s_tx_frame == 8'd160);

   // The idle timer
   reg         s_rx_last;                    // the synchronized rx a clock ago
   wire        s_rx_strobe;                  // the receiver completed a byte
   wire        s_rx_activity = (s_rx_pipe[1] ^ s_rx_last) | s_rx_strobe;
   reg   [3:0] s_idle_sub;                   // baud edges into the current bit time of silence
   reg   [7:0] s_idle_cnt;                   // bit times of silence, stops at idle_thresh
   reg         s_idle_flag;
   wire  [7:0] s_idle_cnt_inc = s_idle_cnt + 8'd1;

   assign tx_buf_empty = ~tx_fifo_full;
   assign tx_idle      = ~s_tx_act;
   assign de           = de_pol ^ (de_en & s_tx_act);
   assign idle_flag    = s_idle_flag;

   always @(posedge clk)
   begin
      if (~rst_n)
         s_rx_pipe <= 2'h0;
      else
         s_rx_pipe <= { s_rx_pipe[0], rx };
   end

   always @(posedge clk)
   begin
      if (~rst_n)
         s_baud_edge_r <= 1'b0;
      else
         s_baud_edge_r <= s_baud_ref;
   end

   // ===================================================================
   // The transmit FIFO: the rising edge of tx_wr queues a byte (dropped
   // when full); a byte goes to the transmitter's buffer as soon as that
   // is free
   // ===================================================================
   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         tx_wr_ptr    <= 4'h0;
         tx_rd_ptr    <= 4'h0;
         s_tx_wr_last <= 1'b0;
      end
      else
      begin
         s_tx_wr_last <= tx_wr;

         if (tx_push)
         begin
            tx_fifo[tx_wr_ptr[2:0]] <= tx_d;
            tx_wr_ptr <= tx_wr_ptr + 4'd1;
         end

         if (tx_pop)
            tx_rd_ptr <= tx_rd_ptr + 4'd1;
      end
   end

   // ===================================================================
   // The transmit path's occupancy
   // ===================================================================
   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         s_tx_act   <= 1'b0;
         s_tx_frame <= 8'd161;
         s_tx_last  <= 1'b1;
      end
      else
      begin
         s_tx_last <= tx;

         if (s_tx_start)
            s_tx_frame <= {7'h0, s_baud_edge};
         else if (s_baud_edge && !s_tx_frame_idle)
            s_tx_frame <= s_tx_frame + 8'd1;

         // active from a byte queued (or handed to the transmitter); free
         // at the end of a stop bit when no byte waits in the FIFO or the
         // transmitter's buffer (one queued in this very clock keeps it)
         if (tx_push || tx_pop)
            s_tx_act <= 1'b1;
         else if (s_tx_done && s_tx8n_empty && tx_fifo_empty)
            s_tx_act <= 1'b0;
      end
   end

   // ===================================================================
   // The idle timer: bit times of receive silence
   // ===================================================================
   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         s_rx_last   <= 1'b0;
         s_idle_sub  <= 4'h0;
         s_idle_cnt  <= 8'h0;
         s_idle_flag <= 1'b0;
      end
      else
      begin
         s_rx_last <= s_rx_pipe[1];

         if (idle_clr)
            s_idle_flag <= 1'b0;

         if (s_rx_activity)
         begin
            s_idle_sub <= 4'h0;
            s_idle_cnt <= 8'h0;
         end
         else if (s_baud_edge)
         begin
            s_idle_sub <= s_idle_sub + 4'd1;

            // a bit time of silence; the count stops at the threshold
            // (idle_thresh 0: it never moves, the flag never sets)
            if (s_idle_sub == 4'hF && s_idle_cnt < idle_thresh)
            begin
               s_idle_cnt <= s_idle_cnt_inc;
               if (s_idle_cnt_inc == idle_thresh)
                  s_idle_flag <= 1'b1;         // (a set and a clear in one clock: the set wins)
            end
         end
      end
   end

   // ===================================================================
   // Create a RX8N Uart Receiver module for Debug interface
   // ===================================================================
   lisa_rx8n i_lisa_rx8n_2
   (
       .clk        ( clk             ),   // Connect sample clock
       .rst_n      ( rst_n           ),   // Connect the reset signal
       .baud_ref   ( s_baud_ref      ),   // Baud rate reference
       .rxd        ( s_rx_pipe[1]    ),   // Connect the rx data
       .rd         ( rx_rd           ),   // Connect the rd signal
       .data_avail ( rx_data_avail   ),   // Connect data avail signal
       .d          ( rx_d            ),   // Connect the data
       .rx_strobe  ( s_rx_strobe     ),   // a byte completed: receive activity for the idle timer
    /* verilator lint_off PINCONNECTEMPTY */
       .rx_byte    (                 ),
    /* verilator lint_on PINCONNECTEMPTY */
       .overrun    ( rx_overrun      )
   );

   // ===================================================================
   // Create a TX8N  Uart Transmitter module for Debug interface
   // ===================================================================
   lisa_tx8n i_lisa_tx8n_2
   (
       .clk       ( clk            ),  // Connect clock
       .rst_n     ( rst_n          ),  // Connect the reset signal
       .baud_ref  ( s_baud_ref     ),  // Baud rate reference
       .txd       ( tx             ),  // Connect the TX data
       .wr        ( tx_pop         ),  // the next byte from the FIFO
       .d         ( tx_fifo[tx_rd_ptr[2:0]] ),
       .buf_empty ( s_tx8n_empty   )   // its one-byte buffer is free
   );

   // ===================================================================
   // Create a baud rate generator
   // ===================================================================
   debug_brg i_lisa_brg
   (
       .clk      ( clk        ),       // Connect clock
       .rst_n    ( rst_n      ),       // Connect the reset signal
       .wr       ( s_brg_wr   ),       // Connect the tx write signal
       .d        ( s_brg_d    ),       // Connect the data
       .baud_set ( 1'b0       ),
       .baud_div ( 7'h0       ),
       .baud_ref ( s_baud_ref )        // Baud rate reference
   );

   // ==========================================================================
   // Instantiate the autobaud detector
   // ==========================================================================
   debug_autobaud i_lisa_autobaud
   (
      // Timing and reset inputs
      .clk       ( clk                       ), // System clock
      .rst_n     ( rst_async_n               ), // Active low reset
      .disabled  ( autobaud_disable          ), // Disabled if set externally
      .rx1       ( s_rx_pipe[1]              ), // Input from the UART
      .rx2       ( 1'b0                      ), // Input from the UART
      .rx3       ( 1'b0                      ), // Input from the UART
      .wr        ( s_auto_brg_wr             ), // Write the baud rate
      .div       ( s_auto_brg_d              ), // The divisor
    /* verilator lint_off PINCONNECTEMPTY */
      .rx_sel    (                           )  // Selected RX input
    /* verilator lint_on PINCONNECTEMPTY */
   );

   // the generator takes the bit period in clocks (since the second
   // chip): the autobaud's measurement when it fires, else the CPU's
   // divisor, whose meaning stays a bit of 32 x (brg_d + 1) clocks
   assign s_brg_wr = brg_wr | s_auto_brg_wr;
   assign s_brg_d  = s_auto_brg_wr ? s_auto_brg_d : {1'b0, brg_d, 5'h0} + 14'd32;


endmodule

