/*
==============================================================================
lisa_spi.v:  A SPI master for the LISA core (RESPIN 29).

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

A byte-at-a-time SPI master on its own pins (lisa_io_mux.v), so the core
reaches a SPI flash or SD card without the QSPI bus it fetches from: no
transaction can wait on the core's own instruction fetch.

Registers (peripheral space):

   0x28  DATA    write: the byte to send, starts the transfer
                 read:  the byte received (the shift register: valid once
                        the transfer is done); clears DONE.  A write while
                        BUSY is ignored
   0x29  CTRL    [0] CS0, [1] CS1 asserted (the pins are active low)
                 [2] CPOL, [3] CPHA
                 [4] CLAIM: take the TTLC's I/O pins (mux mode 3)
                 [6:5] MISO from ui_in[0], [1], [2], [7]
                 [7] IE: interrupt (source 7) while DONE
   0x2A  DIV     half an SCLK period is DIV + 1 clocks
   0x2B  STATUS  read: [0] BUSY (a byte sending or waiting for the pins),
                 [1] DONE, [2] OWNED (the TTLC's pins are granted),
                 [3] TTLC_WAIT (the TTLC wants to scan: release them)

Mode 3 (the TTLC's pins): SCLK on uo[7], MOSI / CS0 / CS1 on the TTLC's
data lines uo[0..2] while OWNED.  Outside it those lines carry the TTLC's
data, which can hold a select low, so the SCLK pin of mode 3 (sclk_m3)
follows the master only from the clock after the grant (own_r) to the
release, and holds its level otherwise: a CPOL written before the grant
reaches the pin a clock after the selects are the SPI's.  Claim with
the selects deasserted and assert them once OWNED.  CLAIM is granted between scans (the
shift-register I/O idle and no scan requested); a scan the TTLC requests
while the pins are owned waits (tt_um_pettit_lisa.v) and the ICU with it, and the
pins go back when CLAIM is cleared and the last byte is out.  A byte
written while CLAIM is set and not yet granted waits for the grant.

The phases: CPHA 0 presents bit 7 before the first edge, samples MISO on
the leading edges and shifts on the trailing ones; CPHA 1 shifts on the
leading edges (after the first) and samples on the trailing ones.  MISO is
sampled as the edge is made, half a period after the device's own shift.
==============================================================================
*/

module lisa_spi
(
   input  wire          clk,
   input  wire          rst_n,

   // The peripheral bus
   input  wire [6:0]    d_addr,
   input  wire [7:0]    d_i,
   input  wire          d_periph,
   input  wire          d_we,
   input  wire          d_rd,
   output reg  [7:0]    d_o,

   // The pins
   input  wire [3:0]    miso_in,       // {ui_in[7], ui_in[2:0]}
   output wire          sclk,
   output wire          sclk_m3,       // SCLK on the TTLC's pins: moves only while owned
   output wire          mosi,
   output wire [1:0]    cs_n,

   // The interlock with the TTLC's shift-register I/O
   input  wire          scan_req,      // a scan requested (FLAG_O, or one waiting)
   input  wire          scan_busy,     // a scan in progress
   output reg           owned,         // the mode-3 pins are the SPI's
   output wire          xfer_busy,     // a byte under way or waiting (RESPIN 30's START waits on it)
   output wire          irq
);

   reg   [7:0]    ctrl;
   reg   [7:0]    div;
   reg   [7:0]    shreg;
   reg   [7:0]    cnt;
   reg   [3:0]    nshift;              // shifts done in this byte
   reg            sclk_int;            // SCLK before CPOL
   reg            first;               // CPHA 1: the first leading edge shifts nothing
   reg            miso_l;
   reg            busy;
   reg            pend;
   reg            done;
   reg            own_r;               // owned, a clock later
   reg            scan_req_r;          // scan_req a clock later: 0x2B's bit (RESPIN 38 - FLAG_O
                                       // is the ICU's falling-edge flop, its read was a half clock)
   reg            sclk_hold;           // the mode-3 SCLK while not owned
   wire           miso;
   wire           claim;
   wire           cpha;
   wire           go;
   wire           wr_data;

   assign claim   = ctrl[4];
   assign cpha    = ctrl[3];
   assign miso    = miso_in[ctrl[6:5]];
   assign sclk    = sclk_int ^ ctrl[2];
   assign mosi    = shreg[7];
   assign cs_n    = ~ctrl[1:0];
   assign irq     = done & ctrl[7];
   assign sclk_m3 = own_r ? sclk : sclk_hold;
   // on the claimed pins a byte also waits out a scan the core started
   // while holding them (RESPIN 30): the scan has the data pins
   assign go      = pend && !busy && (!claim || (owned && !scan_busy));
   assign xfer_busy = busy | pend;
   assign wr_data = d_periph && d_we && d_addr == 7'h28;

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         ctrl     <= 8'h0;
         div      <= 8'h3;
         shreg    <= 8'h0;
         cnt      <= 8'h0;
         nshift   <= 4'h0;
         sclk_int <= 1'b0;
         first    <= 1'b0;
         miso_l   <= 1'b0;
         busy     <= 1'b0;
         pend     <= 1'b0;
         done     <= 1'b0;
         owned    <= 1'b0;
         own_r     <= 1'b0;
         sclk_hold <= 1'b0;
         scan_req_r <= 1'b0;
      end
      else
      begin
         scan_req_r <= scan_req;
         own_r <= owned;
         if (own_r)
            sclk_hold <= sclk;

         if (d_periph && d_we && d_addr == 7'h29)
            ctrl <= d_i;
         if (d_periph && d_we && d_addr == 7'h2A)
            div <= d_i;

         // The pins of mode 3: granted between scans, kept until CLAIM is
         // cleared and the byte in flight is out
         if (claim)
            owned <= owned | (!scan_busy && !scan_req);
         else if (!busy && !pend)
            owned <= 1'b0;

         // DONE: a byte has come in; reading or writing DATA clears it
         if (wr_data || (d_periph && d_rd && d_addr == 7'h28))
            done <= 1'b0;

         if (wr_data && !busy)
         begin
            shreg <= d_i;
            pend  <= 1'b1;
         end
         else if (go)
         begin
            pend     <= 1'b0;
            busy     <= 1'b1;
            cnt      <= div;
            nshift   <= 4'h0;
            sclk_int <= 1'b0;
            first    <= 1'b1;
         end
         else if (busy)
         begin
            if (cnt != 8'h0)
               cnt <= cnt - 8'h1;
            else
            begin
               cnt      <= div;
               sclk_int <= ~sclk_int;
               if (!sclk_int)
               begin
                  // The leading edge
                  first <= 1'b0;
                  if (!cpha)
                     miso_l <= miso;
                  else if (!first)
                  begin
                     shreg  <= {shreg[6:0], miso_l};
                     nshift <= nshift + 4'h1;
                  end
               end
               else
               begin
                  // The trailing edge
                  if (!cpha || nshift == 4'h7)
                  begin
                     shreg  <= {shreg[6:0], cpha ? miso : miso_l};
                     nshift <= nshift + 4'h1;
                     if (nshift == 4'h7)
                     begin
                        busy <= 1'b0;
                        done <= 1'b1;
                     end
                  end
                  else
                     miso_l <= miso;
               end
            end
         end
      end
   end

   always @*
   begin
      case (d_addr)
      7'h28:   d_o = shreg;
      7'h29:   d_o = ctrl;
      7'h2A:   d_o = div;
      7'h2B:   d_o = {4'h0, scan_req_r & owned, owned, done, busy | pend};
      default: d_o = 8'h0;
      endcase
   end

endmodule
