// The Ethernet TTLC I/O bridge with the inside chains, scanned by the
// chip's shift_reg_io (the way tt_um_lisa drives the TTLC Pmod): the
// test drives the MII pins as the PHY and the scan as the TTLC.
`timescale 1ns / 1ps
module tb_eth
(
   input  wire          clk,            // the system clock
   input  wire          rst_n,
   input  wire          mii_rx_clk,
   input  wire          mii_rx_dv,
   input  wire          mii_rx_er,
   input  wire [3:0]    mii_rxd,
   input  wire          mii_tx_clk,
   output wire          mii_tx_en,
   output wire [3:0]    mii_txd,
   input  wire          pmod_sel,
   // the scan
   input  wire          scan_start,
   input  wire [47:0]   scan_out,       // what the TTLC sends to the 595 chains
   output wire [47:0]   scan_in,        // what it read from the 165 chains
   output wire          scan_busy,
   // the two registers the host sees
   output wire [47:0]   ttlc_in,
   output wire [47:0]   ttlc_out,
   output wire          rx_act,
   output wire          accepted,
   output wire          tx_act
);

   wire [2:0]     dout;
   wire [2:0]     din;
   wire           latch;
   wire           sclk;

   shift_reg_io scan
   (
      .clk           ( clk        ),
      .rst_n         ( rst_n      ),
      .data_in       ( din        ),
      .output_buffer ( scan_out   ),
      .clk_div       ( 2'b01      ),      // clk/4, as test.py sets 0x1c
      .start         ( scan_start ),
      .io_busy       ( scan_busy  ),
      .data_out      ( dout       ),
      .latch         ( latch      ),
      .shift_clk     ( sclk       ),
      .input_buffer  ( scan_in    )
   );

   ttlc_chains_fpga chains
   (
      .clk        ( clk      ),
      .rst_n      ( rst_n    ),
      .sclk       ( sclk     ),
      .latch      ( latch    ),
      .dout       ( dout     ),
      .din        ( din      ),
      .inputs     ( ttlc_in  ),
      .outputs    ( ttlc_out )
   );

   eth_ttlc #( .TICKS_PER_US(40), .EVENT_GAP_US(20) ) eth
   (
      .clk        ( clk        ),
      .rst_n      ( rst_n      ),
      .mii_rx_clk ( mii_rx_clk ),
      .mii_rx_dv  ( mii_rx_dv  ),
      .mii_rx_er  ( mii_rx_er  ),
      .mii_rxd    ( mii_rxd    ),
      .mii_tx_clk ( mii_tx_clk ),
      .mii_tx_en  ( mii_tx_en  ),
      .mii_txd    ( mii_txd    ),
      .ttlc_in    ( ttlc_in    ),
      .ttlc_out   ( ttlc_out   ),
      .pmod_sel   ( pmod_sel   ),
      .rx_act     ( rx_act     ),
      .accepted   ( accepted   ),
      .tx_act     ( tx_act     )
   );

endmodule
