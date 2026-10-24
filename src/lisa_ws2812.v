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
   0x41  WS_STAT   read: [0] FULL_A, [1] FULL_B, [2] BUSY (a pixel being
                   sent), [3] DONE (the line has been low for the reset time
                   since the last pixel: the string latched), [4] UNDERRUN
                   (a pixel came after the line had gone low between pixels),
                   [5] NEXT (the half the engine sends next);
                   write: [0] / [1] set FULL_A / FULL_B (the half is loaded),
                   [4] a 1 clears UNDERRUN
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

   assign wr   = d_periph && d_we;
   assign en   = ctrl[0];
   assign pin  = ctrl[3:1];
   assign ie   = ctrl[4];
   assign irq  = ctrl[0] && ctrl[4] && !(full[0] && full[1]);
   // the pixel's bit: byte bitn[4:3] of the half (G, R, B), MSB first
   assign idx  = (next ? 6'd24 : 6'd0) + {1'b0, bitn[4:3], 3'b000} + {3'b000, ~bitn[2:0]};
   assign bitv = pixels[idx];
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
      end
      else
      begin
         if (wr && d_addr == 7'h40) ctrl <= d_i;
         if (wr && d_addr == 7'h42) t0h  <= d_i;
         if (wr && d_addr == 7'h43) t1h  <= d_i;
         if (wr && d_addr == 7'h44) tbit <= d_i;
         if (wr && d_addr == 7'h45) trst <= d_i;
         if (wr && d_addr == 7'h41 && d_i[4])
            underrun <= 1'b0;

         if (!ctrl[0])
         begin
            // off: nothing sent, the halves forgotten, A next
            busy  <= 1'b0;
            line  <= 1'b0;
            full  <= 2'b00;
            next  <= 1'b0;
            done  <= 1'b1;
            low   <= 14'd0;
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
                  // the pixel is out: its half is free, the other is next
                  bitn <= 5'd0;
                  full[next] <= 1'b0;
                  next <= ~next;
                  busy <= full[~next];
                  low  <= 14'd0;
               end
            end
         end
         else
         begin
            line <= 1'b0;
            if (full[next])
            begin
               // a pixel: a new frame after DONE, else a late one (a
               // FULL written in the clock the last pixel ended is not)
               if (!done && low != 14'd0)
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
         if (wr && d_addr == 7'h41 && ctrl[0])
         begin
            if (d_i[0]) full[0] <= 1'b1;
            if (d_i[1]) full[1] <= 1'b1;
         end
      end
   end

   always @*
   begin
      case (d_addr)
      7'h40:   d_o = ctrl;
      7'h41:   d_o = {2'b00, next, underrun, done, busy, full};
      7'h42:   d_o = t0h;
      7'h43:   d_o = t1h;
      7'h44:   d_o = tbit;
      7'h45:   d_o = trst;
      default: d_o = 8'h0;
      endcase
   end

endmodule
