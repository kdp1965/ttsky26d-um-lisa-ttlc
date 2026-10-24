/*
==============================================================================
lisa_ttlcio.v:  The TTLC's I/O for the LISA core (RESPIN 30).

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


The TTLC's I/O vector (ttlc_io.v: the 48 outputs, the 48 inputs, the 64
storage bits, port_in, RR and the constants) as 24 bytes to the LISA core,
byte n = bits 8n+7..8n, through an index and a data register,
and a scan of the 74HC595 / 74HC165 chains the core can start itself:

   0x2C  TIDX    the byte index, 0-23 (r/w)
   0x2D  TDATA   read: byte TIDX; write: byte TIDX of the outputs (0-5)
                 or of the storage bits (12-15: bits 0-31, 20-23: bits
                 32-63, RESPIN 31), others ignored; a read or a write moves
                 TIDX to the next byte (23 wraps to 0)
   0x2E  TCTRL   write: [0] START a scan (and clear DONE)
                 read:  [0] BUSY, [1] DONE (a scan has ended since the
                 last read: cleared by the read), [2] START pending,
                 [3] TTLC_WAIT (the ICU holds at a scan the claim keeps
                 back), [4] OWNED (the SPI master's claim, 0x29 bit 4)

The core reads at any time without disturbing the ICU: the inputs change
only at the end of a scan (DONE tells a read that spans one), the outputs
and storage bits as the ICU writes them.  A byte written in the clock the
ICU writes one of its bits keeps the ICU's bit.

For updates the ICU must not see half done, the core takes the claim of
the SPI master (0x29 bit 4): the ICU's own scans wait while it is held, so
the ICU stops at its next scan (TTLC_WAIT), then the core writes the
outputs, starts a scan of its own (allowed while it holds the claim: the
mode-3 data pins go back to the chains for the scan), reads the inputs and
releases the claim.  A START waits for the SPI master to finish its byte,
and the SPI master waits for the scan.  With the ICU halted (ttlc_run, the
reset state) the chains are simply the core's: 48 outputs and 48 inputs.
*/

module lisa_ttlcio
(
   input  wire          clk,
   input  wire          rst_n,

   input  wire [6:0]    d_addr,
   input  wire [7:0]    d_i,
   input  wire          d_periph,
   input  wire          d_we,
   input  wire          d_rd,
   output reg  [7:0]    d_o,

   // ttlc_io.v's byte port
   output reg  [4:0]    idx,           // the byte
   output wire [7:0]    wdata,
   output wire          we,            // write byte idx
   input  wire [7:0]    rdata,         // byte idx

   // the scan
   input  wire          scan_busy,     // shift_reg_io's io_busy
   input  wire          spi_busy,      // the SPI master has a byte under way
   input  wire          ttlc_wait,     // the ICU waits on the claim
   input  wire          owned,         // the claim is held
   output wire          start          // start a scan
);

   reg            pend;                // a START not yet taken
   reg            done;
   reg            busy_r;
   wire           acc;                 // TDATA read or written

   assign wdata = d_i;
   assign we    = d_periph && d_we && d_addr == 7'h2D;
   assign acc   = we || (d_periph && d_rd && d_addr == 7'h2D);
   assign start = pend && !spi_busy;

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         idx    <= 5'h0;
         pend   <= 1'b0;
         done   <= 1'b0;
         busy_r <= 1'b0;
      end
      else
      begin
         busy_r <= scan_busy;

         if (d_periph && d_we && d_addr == 7'h2C)
            idx <= d_i[4:0];
         else if (acc)
            idx <= idx == 5'd23 ? 5'h0 : idx + 5'h1;

         // shift_reg_io takes a start only while idle: the START waits
         // until the scan it asks for begins
         if (d_periph && d_we && d_addr == 7'h2E && d_i[0])
            pend <= 1'b1;
         else if (start && !scan_busy)
            pend <= 1'b0;

         // DONE is a scan's end with no START still waiting: a START
         // written during a scan (the ICU's) is not done by that scan
         if (d_periph && d_we && d_addr == 7'h2E && d_i[0])
            done <= 1'b0;
         else if (busy_r && !scan_busy && !pend)
            done <= 1'b1;
         else if (d_periph && d_rd && d_addr == 7'h2E)
            done <= 1'b0;
      end
   end

   always @*
   begin
      case (d_addr)
      7'h2C:   d_o = {3'h0, idx};
      7'h2D:   d_o = rdata;
      7'h2E:   d_o = {3'h0, owned, ttlc_wait, pend, done, scan_busy};
      default: d_o = 8'h0;
      endcase
   end

endmodule
