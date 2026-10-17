// LISA (tt_um_lisa, this repository's RTL) on the Digilent Arty A7-35T.
//
// The Tiny Tapeout pins come out on three Pmods in the demo board's order
// (Pmod pins 1-4 and 7-10 are bits 0-3 and 4-7):
//
//   JA   ui_in    inputs to the design, pulled down the way the demo
//                 board's RP2040 drives them (b_div 0, autobaud enabled)
//   JB   uo_out
//   JC   uio      bidirectional: the QSPI flash / PSRAM Pmod goes here.
//                 JB and JC are the Arty's high-speed Pmods; JA and JD
//                 have 200 ohm series resistors.
//   JD   unused
//
// The USB-UART is the debug UART: uart_txd_in (from the host) and JA pin 4
// are ANDed into ui_in[3] (rx) - a UART idles high and the unused one is
// pulled up, so whichever is driven gets through, as on the demo board
// where the RP2040 and the Pmod share the pin; uo_out[4] (tx) drives both
// uart_rxd_out and JB pin 7.  Clock: the 100 MHz oscillator through an
// MMCM to the project clock (lisa_arty_clk.v, CLK_DIVIDE).  Reset: the
// RESET button (ck_rst, active low) or the MMCM not locked, asserted
// asynchronously and held for 65536 clocks after both are clear, so the
// synchronous resets see clock edges, as on the demo board.  LEDs: LD4
// clock locked, LD5 in reset, LD6 tx, LD7 rx.
module lisa_arty
#(
   parameter CLK_DIVIDE = 20       // 100 MHz / (CLK_DIVIDE / 10): 20 = 50 MHz, 25 = 40, 15 = 66.67
)
(
   input  wire        CLK100MHZ,
   input  wire        ck_rst,         // RESET button, active low
   input  wire [3:0]  sw,            // unused
   output wire [3:0]  led,
   input  wire [7:0]  ja,             // ui_in
   output wire [7:0]  jb,             // uo_out
   inout  wire [7:0]  jc,             // uio
   input  wire        uart_txd_in,    // from the host
   output wire        uart_rxd_out    // to the host
);

   wire                 clk;
   wire                 locked;

   lisa_arty_clk #(.CLKOUT_DIVIDE(CLK_DIVIDE)) clkgen
   (
      .clk_in     ( CLK100MHZ ),
      .clk_out    ( clk       ),
      .locked     ( locked    )
   );

   // Reset: asynchronous assert, released 65536 clocks after the button
   // and the MMCM's lock allow it
   wire                 rst_async_n = ck_rst & locked;
   reg  [15:0]          rst_cnt;
   reg                  rst_n_r;

   always @(posedge clk or negedge rst_async_n)
   begin
      if (!rst_async_n)
      begin
         rst_cnt <= 16'd0;
         rst_n_r <= 1'b0;
      end
      else if (&rst_cnt)
         rst_n_r <= 1'b1;
      else
         rst_cnt <= rst_cnt + 1'b1;
   end

   wire                 rst_n = rst_n_r;

   // The Tiny Tapeout ports
   wire [7:0]           ui_in;
   wire [7:0]           uo_out;
   wire [7:0]           uio_in;
   wire [7:0]           uio_out;
   wire [7:0]           uio_oe;

   assign ui_in  = {ja[7:4], uart_txd_in & ja[3], ja[2:0]};
   assign jb     = uo_out;
   assign uart_rxd_out = uo_out[4];
   assign uio_in = jc;

   genvar i;
   generate
      for (i = 0; i < 8; i = i + 1)
      begin : UIO
         assign jc[i] = uio_oe[i] ? uio_out[i] : 1'bz;
      end
   endgenerate

   tt_um_lisa lisa
   (
      .ui_in      ( ui_in   ),
      .uo_out     ( uo_out  ),
      .uio_in     ( uio_in  ),
      .uio_out    ( uio_out ),
      .uio_oe     ( uio_oe  ),
      .ena        ( 1'b1    ),
      .clk        ( clk     ),
      .rst_n      ( rst_n   )
   );

   assign led = {ui_in[3], uo_out[4], ~rst_n, locked};

endmodule
