/*
==============================================================================
lisa_ws2812.v:  A WS2812B LED string driver for the LISA core (RESPIN 33).

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


The bit engine of a WS2812B (NeoPixel) driver (Ken, 2026-10-24) for designs
that do not use the TTLC's I/O: the pixels are held in the TTLC's 48 output
flops (ttlc_io.v output_pins), which the core already writes through the
TTLC I/O window (RESPIN 30, TIDX / TDATA) - two pixels, half A in bytes
0-2 and half B in bytes 3-5, each G, R, B, sent MSB first - and the line
goes out on one of the TTLC's mux-3 pins.  While one half is sent the core
fills the other (a pixel is 24 x 1.25 us = 30 us, 1500 clocks at 50 MHz).
The MC14500B must not run meanwhile (it writes the same flops): it is
halted from reset until the debugger starts it.

   0x40  WS_CTRL   [0] EN: WS mode - the selected pin carries the line, the
                   other four of uo[0], uo[1], uo[2], uo[5], uo[6] are held
                   low in mux 3 (the TTLC's data, latch and shift clock);
                   [3:1] PIN: 0 uo[0], 1 uo[1], 2 uo[2], 3 uo[5], 4 uo[6];
                   [4] IE: a free half requests the TTLC's interrupt source
                   (INT_STATUS bit 5, vector 6) in place of the TTLC's toggle
                   (DMA: FRAME); [5] DMA: frames from the PSRAM
                   (below); [6] REPEAT: DMA frames back to back
   0x41  WS_STAT   read: [0] FULL_A, [1] FULL_B, [2] BUSY (a pixel being
                   sent), [3] DONE (the line has been low for the reset time
                   since the last pixel: the string latched), [4] UNDERRUN
                   (a pixel came after the line had gone low between pixels),
                   [5] NEXT (the half the engine sends next; DMA: the pixel
                   of the group), [6] ACTIVE (DMA: a frame running), [7]
                   FRAME (DMA: a frame ended, its reset time too);
                   write: [0] / [1] set FULL_A / FULL_B (the half is loaded),
                   [4] a 1 clears UNDERRUN, [6] START (DMA: a frame), [7]
                   a 1 clears FRAME
   0x42  WS_T0H    a 0 bit is high T0H clocks        (reset 20: 0.40 us at 50 MHz)
   0x43  WS_T1H    a 1 bit is high T1H clocks        (reset 40: 0.80 us)
   0x44  WS_TBIT   a bit is TBIT + 1 clocks          (reset 62: 1.26 us)
   0x45  WS_TRST   the reset is (TRST + 1) x 64 clocks low (reset 219: 282 us,
                   the WS2812B's 280; the older parts need 50)

The engine sends half A, then B, then A ..., each once it is FULL, clearing
FULL as the half's last bit ends.  With the next half not full the line
stays low: when the core fills it before the reset time has passed the
frame goes on (UNDERRUN is set: a string may have latched at the gap), and
after the reset time DONE is set and the next pixel starts a new frame -
at half A: every frame does, so software fills A, B, A, ... from DONE on.
The interrupt request is a level: EN, IE and a half not full - the core
drops IE after the frame's last pixel.

DMA (RESPIN 35, Ken's idea, 2026-10-24): WS_CTRL [5] DMA sends a frame
straight from a buffer in the PSRAM through the TTLC's instruction fetch -
the MC14500B is halted in WS mode anyway, and a fetch group (three words,
48 bits) is two pixels, the size of the two halves.  The output flops hold
the frame instead of pixels: bytes 0-1 BASE, the buffer's data address in
256-byte units (it starts on a 256-byte boundary), bytes 2-3 LEN, the
pixels [12:0] (up to 8191; the buffer is G, R, B a pixel, in order).
WS_STAT bit 6 written 1 is START: the data cache is flushed first (the
CPU's pixels may be dirty in it: the debugger's flush, the dirty lines
only), then the fetch restarts at group 0 of the buffer, on the data
cache's select and base, and the engine sends group A's two pixels while
group B is fetched - a group lasts 3600 clocks at TBIT 74, its fetch ~70
at clk/2.  After the last pixel's reset time the frame is done: ACTIVE
(WS_STAT bit 6) drops, or with WS_CTRL [6] REPEAT the next frame starts
from the same buffer (flushed again); either way FRAME (bit 7, sticky,
written 1 to clear) is set.  The request is EN, IE and FRAME - a frame
interrupt also when repeating.  FULL_A / FULL_B and the halves are not used; UNDERRUN means a
group came late (more than 8 clocks low between pixels).  The buffer must
not change during a frame.
*/

module lisa_ws2812
(
   input  wire          clk,
   input  wire          rst_n,

   input  wire [6:0]    d_addr,
   input  wire [7:0]    d_i,
   input  wire          d_periph,
   input  wire          d_we,
   output reg  [7:0]    d_o,

   input  wire [47:0]   pixels,        // the TTLC's output_pins: half A [23:0], half B [47:24]

   // DMA (RESPIN 35): the TTLC's fetch (ttlc_fetch.v) brings the pixels
   input  wire [47:0]   grp,           // group A: two pixels
   input  wire          grp_valid,
   input  wire          fetch_idle,    // no fill in flight
   input  wire          flush_ack,     // the data cache's flush is done (or the cache is off)
   output reg           flush_req,
   output wire          dma_fetch,     // the TTLC fetch port is the driver's
   output reg           restart,       // the fetch to group 0 (a pulse)
   output reg           adv,           // group A sent: the next one (a pulse)
   output wire [11:0]   last_grp,      // no prefetch past it
   output wire [15:0]   base,          // the buffer's data address / 256

   output wire          en,            // WS mode (lisa_io_mux.v)
   output wire [4:0]    pins,          // uo[6], uo[5], uo[2], uo[1], uo[0] in mux 3
   output wire          ie,
   output wire          irq
);

   reg   [7:0]    ctrl;
   reg   [7:0]    t0h, t1h, tbit, trst;
   reg   [1:0]    full;
   reg            next;                // the half sent next
   reg            busy;
   reg            done;
   reg            underrun;
   reg   [4:0]    bitn;                // the bit of the pixel, 0..23
   reg   [7:0]    btime;               // the clock of the bit
   reg   [13:0]   low;                 // clocks low since the last pixel ({trst, 6'b0} is the reset)
   reg            line;
   wire           wr;
   wire  [5:0]    idx;
   wire           bitv;
   wire  [2:0]    pin;
   wire           dma;
   wire  [12:0]   len;
   wire  [12:0]   len_m1;
   wire  [12:0]   pcount_p1;
   wire           have;
   reg   [1:0]    dst;                 // DMA: IDLE, FLUSH, SYNC (wait for the fetch), SEND
   reg   [12:0]   pcount;              // DMA: the pixels sent
   reg            pg;                  // DMA: the pixel of group A sent next
   reg            frame_f;             // DMA: a frame ended (sticky, write 1 to clear)

   localparam [1:0] D_IDLE  = 2'd0;
   localparam [1:0] D_FLUSH = 2'd1;
   localparam [1:0] D_SYNC  = 2'd2;
   localparam [1:0] D_SEND  = 2'd3;

   assign wr   = d_periph && d_we;
   assign en   = ctrl[0];
   assign pin  = ctrl[3:1];
   assign ie   = ctrl[4];
   assign dma  = ctrl[5];
   assign irq  = ctrl[0] && ctrl[4] && (dma ? frame_f : !(full[0] && full[1]));
   // the pixel's bit: byte bitn[4:3] of the half (G, R, B), MSB first
   assign idx  = ((dma ? pg : next) ? 6'd24 : 6'd0) + {1'b0, bitn[4:3], 3'b000} + {3'b000, ~bitn[2:0]};
   assign bitv = dma ? grp[idx] : pixels[idx];
   assign base      = pixels[15:0];
   assign len       = pixels[28:16];
   assign len_m1    = len - 13'd1;
   assign last_grp  = len_m1[12:1];
   assign pcount_p1 = pcount + 13'd1;
   assign dma_fetch = ctrl[0] && dma && dst == D_SEND;
   // a pixel to send: the next half full, or group A there (not in the
   // clock the fetch is told to move on or restart: A is still the old one)
   assign have = dma ? dst == D_SEND && grp_valid && !restart && !adv && pcount != len : full[next];
   assign pins = {pin == 3'd4, pin == 3'd3, pin == 3'd2, pin == 3'd1, pin == 3'd0} & {5{line & ctrl[0]}};

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         ctrl     <= 8'h0;
         t0h      <= 8'd20;
         t1h      <= 8'd40;
         tbit     <= 8'd62;
         trst     <= 8'd219;
         full     <= 2'b00;
         next     <= 1'b0;
         busy     <= 1'b0;
         done     <= 1'b1;
         underrun <= 1'b0;
         bitn     <= 5'd0;
         btime    <= 8'd0;
         low      <= 14'd0;
         line     <= 1'b0;
         dst       <= D_IDLE;
         pcount    <= 13'd0;
         pg        <= 1'b0;
         frame_f   <= 1'b0;
         flush_req <= 1'b0;
         restart   <= 1'b0;
         adv       <= 1'b0;
      end
      else
      begin
         restart <= 1'b0;
         adv     <= 1'b0;
         if (wr && d_addr == 7'h40) ctrl <= d_i;
         if (wr && d_addr == 7'h42) t0h  <= d_i;
         if (wr && d_addr == 7'h43) t1h  <= d_i;
         if (wr && d_addr == 7'h44) tbit <= d_i;
         if (wr && d_addr == 7'h45) trst <= d_i;
         if (wr && d_addr == 7'h41 && d_i[4])
            underrun <= 1'b0;
         if (wr && d_addr == 7'h41 && d_i[7])
            frame_f <= 1'b0;

         if (!ctrl[0])
         begin
            // off: nothing sent, the halves forgotten, A next
            busy  <= 1'b0;
            line  <= 1'b0;
            full  <= 2'b00;
            next  <= 1'b0;
            done  <= 1'b1;
            low   <= 14'd0;
            dst       <= D_IDLE;
            flush_req <= 1'b0;
            pcount    <= 13'd0;
            pg        <= 1'b0;
         end
         else if (busy)
         begin
            line <= btime < (bitv ? t1h : t0h);
            if (btime != tbit)
               btime <= btime + 8'd1;
            else
            begin
               btime <= 8'd0;
               if (bitn != 5'd23)
                  bitn <= bitn + 5'd1;
               else
               begin
                  // the pixel is out: its half is free, the other is next;
                  // DMA: the group's second pixel, or A sent - the next group
                  bitn <= 5'd0;
                  low  <= 14'd0;
                  if (dma)
                  begin
                     pcount <= pcount_p1;
                     pg     <= ~pg;
                     if (pg || pcount_p1 == len)
                        adv <= 1'b1;
                     busy   <= !pg && pcount_p1 != len;
                  end
                  else
                  begin
                     full[next] <= 1'b0;
                     next <= ~next;
                     busy <= full[~next];
                  end
               end
            end
         end
         else
         begin
            line <= 1'b0;
            if (have)
            begin
               // a pixel: a new frame after DONE, else a late one (a
               // FULL written in the clock the last pixel ended is not;
               // DMA: the next group takes a few clocks to be A)
               if (!done && (dma ? low[13:3] != 11'd0 : low != 14'd0))
                  underrun <= 1'b1;
               busy  <= 1'b1;
               done  <= 1'b0;
               btime <= 8'd0;
               bitn  <= 5'd0;
            end
            else if (!done)
            begin
               if (low == {trst, 6'b111111})
               begin
                  done <= 1'b1;
                  next <= 1'b0;        // every frame starts at half A
               end
               else
                  low <= low + 14'd1;
            end
         end

         // the core sets FULL (after the engine's own update: a half the
         // engine frees in the clock of the write is the core's again)
         if (wr && d_addr == 7'h41 && ctrl[0] && !dma)
         begin
            if (d_i[0]) full[0] <= 1'b1;
            if (d_i[1]) full[1] <= 1'b1;
         end

         // DMA: a frame - the flush, the fetch at group 0, the pixels, the
         // reset time after them (DONE); START again while one runs
         // starts it over
         if (ctrl[0] && dma)
         begin
            if (wr && d_addr == 7'h41 && d_i[6])
            begin
               dst       <= D_FLUSH;
               flush_req <= 1'b1;
               pcount    <= 13'd0;
               pg        <= 1'b0;
            end
            else
               case (dst)
               D_FLUSH:
                  if (flush_ack)
                  begin
                     flush_req <= 1'b0;
                     dst       <= D_SYNC;
                  end
               D_SYNC:
                  if (fetch_idle)
                  begin
                     restart <= 1'b1;
                     dst     <= D_SEND;
                  end
               D_SEND:
                  if (pcount == len && !busy && done)
                  begin
                     frame_f <= 1'b1;
                     if (ctrl[6])
                     begin
                        dst       <= D_FLUSH;
                        flush_req <= 1'b1;
                        pcount    <= 13'd0;
                        pg        <= 1'b0;
                     end
                     else
                        dst <= D_IDLE;
                  end
               default: ;
               endcase
         end
         else if (!dma)
         begin
            dst       <= D_IDLE;
            flush_req <= 1'b0;
         end
      end
   end

   always @*
   begin
      case (d_addr)
      7'h40:   d_o = ctrl;
      7'h41:   d_o = {frame_f, dst != D_IDLE, dma ? pg : next, underrun, done, busy, full};
      7'h42:   d_o = t0h;
      7'h43:   d_o = t1h;
      7'h44:   d_o = tbit;
      7'h45:   d_o = trst;
      default: d_o = 8'h0;
      endcase
   end

endmodule
