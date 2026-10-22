// LISA (tt_um_pettit_lisa, this repository's RTL) on the Digilent Arty A7-35T.
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
//
// The TTLC's I/O (uo_out[2:0] data, uo_out[5] latch and uo_out[6] shift
// clock to the 74HC595 chains, ui_in[6:4] from the 74HC165 chains) goes
// to copies of the chains inside the FPGA (ttlc_chains_fpga.v) unless SW3
// is up, when JA / JB carry it to a real TTLC Pmod.  The inside chains'
// 48 inputs and 48 outputs are reached over the Ethernet PHY (eth_ttlc.v:
// UDP port 14500 at 192.168.1.200, MAC 02:4c:49:53:41:00).  The PHY runs
// on a 25 MHz reference clock from the MMCM, is reset only by the MMCM's
// lock (so the link survives the RESET button and the UART's DTR), and
// has no MDIO: it autonegotiates from its straps.  LD0 shows it: red a
// frame received, green one for us, blue one sent.  The bridge can also
// take the QSPI Pmod's flash bus (its X command): the chip is held in
// reset meanwhile and JC is driven by the bridge's SPI engine, so a host
// programs the flash over Ethernet in milliseconds instead of through the
// debug UART.
module lisa_arty
#(
   parameter CLK_DIVIDE = 20,      // 100 MHz / (CLK_DIVIDE / 10): 20 = 50 MHz, 25 = 40, 15 = 66.67
   parameter [31:0] ETH_IP = {8'd192, 8'd168, 8'd1, 8'd200}
)
(
   input  wire        CLK100MHZ,
   input  wire        ck_rst,         // RESET button, active low
   input  wire [3:0]  sw,             // SW3: the TTLC Pmod on JA / JB instead of the inside chains
   output wire [3:0]  led,
   output wire        led0_r,
   output wire        led0_g,
   output wire        led0_b,
   input  wire [7:0]  ja,             // ui_in
   output wire [7:0]  jb,             // uo_out
   inout  wire [7:0]  jc,             // uio
   input  wire        uart_txd_in,    // from the host
   output wire        uart_rxd_out,   // to the host
   output wire        eth_ref_clk,    // 25 MHz to the PHY
   output wire        eth_rstn,
   input  wire        eth_rx_clk,
   input  wire        eth_rx_dv,
   input  wire        eth_rxerr,
   input  wire [3:0]  eth_rxd,
   input  wire        eth_tx_clk,
   output wire        eth_tx_en,
   output wire [3:0]  eth_txd
);

   wire                 clk;
   wire                 clk25;
   wire                 locked;

   lisa_arty_clk #(.CLKOUT_DIVIDE(CLK_DIVIDE)) clkgen
   (
      .clk_in     ( CLK100MHZ ),
      .clk_out    ( clk       ),
      .clk25      ( clk25     ),
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

   // The PHY's reset: the lock alone, held 2^20 clocks (26 ms at 40 MHz)
   reg  [20:0]          phy_cnt;

   always @(posedge clk or negedge locked)
   begin
      if (!locked)
         phy_cnt <= 21'd0;
      else if (!phy_cnt[20])
         phy_cnt <= phy_cnt + 1'b1;
   end

   assign eth_rstn = phy_cnt[20];

`ifdef VERILATOR
   assign eth_ref_clk = clk25;
`else
   ODDR #( .DDR_CLK_EDGE("OPPOSITE_EDGE"), .INIT(1'b0), .SRTYPE("SYNC") ) ref_clk_oddr
   (
      .Q  ( eth_ref_clk ),
      .C  ( clk25       ),
      .CE ( 1'b1        ),
      .D1 ( 1'b1        ),
      .D2 ( 1'b0        ),
      .R  ( 1'b0        ),
      .S  ( 1'b0        )
   );
`endif

   // The Tiny Tapeout ports
   wire [7:0]           ui_in;
   wire [7:0]           uo_out;
   wire [7:0]           uio_in;
   wire [7:0]           uio_out;
   wire [7:0]           uio_oe;

   // The TTLC chains inside, or the Pmod's
   wire                 pmod_sel = sw[3];
   wire [2:0]           chain_din;
   wire [47:0]          ttlc_in;
   wire [47:0]          ttlc_out;
   wire [2:0]           ttlc_din = pmod_sel ? ja[6:4] : chain_din;

   assign ui_in  = {ja[7], ttlc_din, uart_txd_in & ja[3], ja[2:0]};
   assign jb     = uo_out;
   assign uart_rxd_out = uo_out[4];
   assign uio_in = jc;

   // JC: the chip's uio, or the bridge's SPI master while it holds the
   // flash bus (CS on uio[0], MOSI [1], MISO [2], SCLK [3]; HOLD#, WP# and
   // the PSRAM selects on [7:4] held high)
   wire                 spi_own;
   wire                 spi_cs_n;
   wire                 spi_sclk;
   wire                 spi_mosi;
   wire [7:0]           spi_drive = {4'b1111, spi_sclk, 1'b1, spi_mosi, spi_cs_n};
   wire [7:0]           spi_oe    = 8'b1111_1011;

   genvar i;
   generate
      for (i = 0; i < 8; i = i + 1)
      begin : UIO
         assign jc[i] = spi_own ? (spi_oe[i] ? spi_drive[i] : 1'bz) : (uio_oe[i] ? uio_out[i] : 1'bz);
      end
   endgenerate

   tt_um_pettit_lisa lisa
   (
      .ui_in      ( ui_in   ),
      .uo_out     ( uo_out  ),
      .uio_in     ( uio_in  ),
      .uio_out    ( uio_out ),
      .uio_oe     ( uio_oe  ),
      .ena        ( 1'b1    ),
      .clk        ( clk     ),
      .rst_n      ( rst_n & ~spi_own )
   );

   ttlc_chains_fpga chains
   (
      .clk        ( clk         ),
      .rst_n      ( rst_n       ),
      .sclk       ( uo_out[6]   ),
      .latch      ( uo_out[5]   ),
      .dout       ( uo_out[2:0] ),
      .din        ( chain_din   ),
      .inputs     ( ttlc_in     ),
      .outputs    ( ttlc_out    )
   );

   wire                 eth_rx_act;
   wire                 eth_accepted;
   wire                 eth_tx_act;

   eth_ttlc #( .IP(ETH_IP), .TICKS_PER_US(1000 / CLK_DIVIDE) ) eth
   (
      .clk        ( clk          ),
      .rst_n      ( rst_n        ),
      .mii_rx_clk ( eth_rx_clk   ),
      .mii_rx_dv  ( eth_rx_dv    ),
      .mii_rx_er  ( eth_rxerr    ),
      .mii_rxd    ( eth_rxd      ),
      .mii_tx_clk ( eth_tx_clk   ),
      .mii_tx_en  ( eth_tx_en    ),
      .mii_txd    ( eth_txd      ),
      .ttlc_in    ( ttlc_in      ),
      .ttlc_out   ( ttlc_out     ),
      .pmod_sel   ( pmod_sel     ),
      .spi_own    ( spi_own      ),
      .spi_cs_n   ( spi_cs_n     ),
      .spi_sclk   ( spi_sclk     ),
      .spi_mosi   ( spi_mosi     ),
      .spi_miso   ( jc[2]        ),
      .rx_act     ( eth_rx_act   ),
      .accepted   ( eth_accepted ),
      .tx_act     ( eth_tx_act   )
   );

   // LD0, each pulse stretched to 2^21 clocks (52 ms at 40 MHz), 1/8 duty
   reg  [20:0]          act_r, act_g, act_b;
   reg  [2:0]           pwm;

   always @(posedge clk or negedge rst_n)
   begin
      if (!rst_n)
      begin
         act_r <= 21'd0;
         act_g <= 21'd0;
         act_b <= 21'd0;
         pwm   <= 3'd0;
      end
      else
      begin
         pwm   <= pwm + 1'b1;
         act_r <= eth_rx_act   ? 21'h1fffff : act_r - (act_r != 21'd0);
         act_g <= eth_accepted ? 21'h1fffff : act_g - (act_g != 21'd0);
         act_b <= eth_tx_act   ? 21'h1fffff : act_b - (act_b != 21'd0);
      end
   end

   assign led0_r = (act_r != 21'd0) && pwm == 3'd0;
   assign led0_g = (act_g != 21'd0) && pwm == 3'd0;
   assign led0_b = (act_b != 21'd0) && pwm == 3'd0;

   assign led = {ui_in[3], uo_out[4], ~rst_n, locked};

endmodule
