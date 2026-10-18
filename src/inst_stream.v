/*
==============================================================================
inst_stream.v:  A streaming instruction fetch for the LISA core.

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

The TT07 inst_cache.v held one line of 4 instructions and fetched a new
line from the flash on every miss: a QSPI command, address and dummy
clocks (about 57 core clocks) for every 4 words, so straight-line code
waited 25 clocks per instruction for the flash (lisa-tools/lisa_sim
--icache on the SDCC suite: 85-90% of the clocks in fills, 86% of the
misses on the next sequential word).  This module keeps the flash read
open instead: a burst is started at the word the core asks for, the QSPI
engine then keeps clocking the following words into a window of 8
consecutive words (10 core clocks each) and pauses, chip select held low,
when it is 3 words ahead of the one the core is on.  The core takes the
words as it fetches them; the words behind the one it is on stay in the
window as long as there is room (up to 4 of them), so a loop of five
instructions or fewer, a polling loop above all, runs from the window.  A
fetch of the word the burst delivers next is waited for; a fetch of any
other word the window does not hold (a jump, a return) ends the burst and
starts one there.  The burst also ends when another client wants the QSPI
(the arbiter's yield: the data cache, the debugger, the TTLC), once the
words ahead are in, and goes on from where it was once the bus is free;
and on the debugger's invalidate.  Once a burst is requested its first
word is always waited for: the arbiter cannot take a request back.
==============================================================================
*/

module inst_stream
(
   input  wire          clk,
   input  wire          rst_n,

   // The instruction bus
   input  wire [19:0]   core_i_addr,      // The physical word: {bank, PC[13:0]} (tt_um_lisa.v)
   output wire [15:0]   core_inst,
   /* verilator lint_off UNUSEDSIGNAL */
   input  wire [15:0]   core_inst_i,      // The TT07 write path: the debugger writes the
   input  wire          core_inst_we,     // flash through its own QSPI client, this is unused
   /* verilator lint_on UNUSEDSIGNAL */
   input  wire          core_i_fetch,
   output wire          core_i_ready,

   // Interface to the QSPI controller
   output wire [19:0]   qspi_addr,           // The word the burst starts at
   input  wire [15:0]   qspi_rdata,          // Read data
   output wire [15:0]   qspi_wdata,          // Data to write (never)
   output wire [1:0]    qspi_wstrb,          // Which bytes to write (none)
   input  wire          qspi_ready,          // A word is on qspi_rdata
   output wire          qspi_ready_ack,      // Taken: read the next one
   input  wire          qspi_xfer_done,      // The transfer has ended
   output reg           qspi_valid,          // Start a transfer
   output wire [3:0]    qspi_xfer_len,       // One word; the burst goes on with qspi_stream
   output reg           qspi_stream,         // Keep the burst open
   input  wire          qspi_yield,          // Another client wants the QSPI: end the burst
   input  wire          inst_cache_invalidate,
   output wire          inst_cache_invalidate_ack
);

   localparam [3:0] DEPTH = 4'd8;            // Words in the window
   localparam [3:0] AHEAD = 4'd3;            // ... at most this many past the one the core is on
   localparam [3:0] REACH = 4'd2;            // A fetch this far past the window waits for the burst

   localparam [1:0] ST_IDLE  = 2'd0;         // No burst
   localparam [1:0] ST_START = 2'd1;         // A burst requested, its first word not in yet
   localparam [1:0] ST_RUN   = 2'd2;         // The burst is open
   localparam [1:0] ST_ABORT = 2'd3;         // Ending it: waiting for xfer_done

   reg   [1:0]          state;
   reg   [127:0]        window;              // Word i at [i*16 +: 16]
   reg   [3:0]          count;               // Words in the window (0..8)
   reg   [19:0]         head_addr;           // The address of word 0
   reg   [2:0]          cur_lo;              // The word the core last took (its low bits: it is within the window)
   reg                  have_pos;            // head_addr + count is where the burst goes on
   reg                  pushed;              // This ready pulse's word has been taken
   reg                  abort_req;           // End the burst as soon as its first word is in

   wire  [19:0]         offset;              // The core's word, counted from word 0
   wire                 near;                // ... it is in the window or just past it
   wire                 hit;
   wire                 waits;               // The burst will deliver it: a fetch to wait on
   wire                 miss;                // Nothing here will: a burst at it
   wire                 flush;
   wire  [3:0]          pos;                 // Where the core is, counted from word 0
   wire  [3:0]          ahead;               // Words in the window past it
   wire                 room;                // The engine may put another word in
   wire                 push;
   wire                 drop;                // ... and the oldest word goes out for it

   assign qspi_wdata    = core_inst_i;
   assign qspi_wstrb    = 2'b00;
   assign qspi_xfer_len = 4'h0;
   assign qspi_addr     = head_addr + {16'h0, count};

   // ==========================================================================
   // The core side: a hit is a word the window holds
   // ==========================================================================
   assign offset       = core_i_addr - head_addr;
   assign near         = (offset[19:4] == 16'h0);
   assign hit          = near && (offset[3:0] < count);
   assign core_i_ready = hit & core_i_fetch;
   assign core_inst    = window[offset[2:0]*16 +: 16];
   assign waits        = have_pos && near && (offset[3:0] >= count) && (offset[3:0] - count <= REACH);
   assign miss         = core_i_fetch & !hit & !waits & !inst_cache_invalidate;

   // ==========================================================================
   // The window: a word from the engine is appended (ready stays high until
   // it is acknowledged, so a word is taken once); when the window is full
   // the oldest word behind the core goes out for it; the engine is not
   // asked for words more than AHEAD past the core (it pauses, chip select
   // low, until the core moves on).  The core is at the word it fetches
   // (in the window or in the burst's reach), else at the one it last took.
   // ==========================================================================
   assign pos      = (core_i_fetch && (hit || waits)) ? offset[3:0] : {1'b0, cur_lo - head_addr[2:0]};
   assign ahead    = (count == 4'd0 || pos >= count) ? 4'd0 : count - pos - 4'd1;
   assign room     = (ahead < AHEAD) && ((count != DEPTH) || (pos != 4'd0));
   assign push     = qspi_ready & !pushed & (state == ST_START || state == ST_RUN) & room;
   assign drop     = push & (count == DEPTH);
   assign qspi_ready_ack = pushed | push;
   assign flush    = (state == ST_IDLE) & (inst_cache_invalidate | miss);
   assign inst_cache_invalidate_ack = inst_cache_invalidate & (state == ST_IDLE) & !have_pos & (count == 4'd0);

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         window    <= 128'h0;
         count     <= 4'd0;
         head_addr <= 20'h0;
         cur_lo    <= 3'h0;
         have_pos  <= 1'b0;
         pushed    <= 1'b0;
      end
      else
      begin
         pushed <= qspi_ready ? (pushed | push) : 1'b0;
         if (flush)
         begin
            // A burst at the core's address, or nothing after an invalidate
            count     <= 4'd0;
            head_addr <= core_i_addr;
            cur_lo    <= core_i_addr[2:0];
            have_pos  <= miss;
         end
         else
         begin
            if (hit & core_i_fetch)
               cur_lo <= core_i_addr[2:0];
            if (drop)
            begin
               window    <= {qspi_rdata, window[127:16]};
               head_addr <= head_addr + 20'h1;
            end
            else if (push)
            begin
               window[count[2:0]*16 +: 16] <= qspi_rdata;
               count <= count + 4'd1;
            end
         end
      end
   end

   // ==========================================================================
   // The burst
   // ==========================================================================
   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         state       <= ST_IDLE;
         qspi_valid  <= 1'b0;
         qspi_stream <= 1'b0;
         abort_req   <= 1'b0;
      end
      else
      begin
         case (state)
            ST_IDLE:
               begin
                  abort_req <= 1'b0;
                  if (inst_cache_invalidate)
                     ;                                   // flushed above, nothing starts
                  else if (miss || (have_pos && room))
                  begin
                     // A burst at the core's word, or on from where the last
                     // one stopped while there is room for its words
                     qspi_valid  <= 1'b1;
                     qspi_stream <= 1'b1;
                     state       <= ST_START;
                  end
               end

            ST_START:
               begin
                  if (miss || inst_cache_invalidate)
                     abort_req <= 1'b1;
                  if (push)
                  begin
                     qspi_valid <= 1'b0;                  // the engine is running
                     state      <= ST_RUN;
                  end
                  else if (qspi_ready && !room)
                  begin
                     // Its first word is here but there is no room for it: the
                     // engine has started, so the burst can be ended (it goes
                     // on from the same word when there is room)
                     qspi_valid  <= 1'b0;
                     qspi_stream <= 1'b0;
                     state       <= ST_ABORT;
                  end
               end

            ST_RUN:
               if (abort_req || miss || inst_cache_invalidate || (qspi_yield && !room))
               begin
                  qspi_stream <= 1'b0;                    // the engine ends the burst
                  state       <= ST_ABORT;
               end

            ST_ABORT:
               begin
                  abort_req <= 1'b0;
                  if (qspi_xfer_done)
                     state <= ST_IDLE;
               end

            default:
               state <= ST_IDLE;
         endcase
      end
   end

endmodule
