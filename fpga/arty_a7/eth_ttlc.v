// The TTLC I/O bridge: the MII MAC, the IP endpoint and the TTLC command
// app together, from the PHY's pins to the two 48-bit registers.
module eth_ttlc
#(
   parameter [47:0]  MAC          = 48'h02_4c_49_53_41_00,
   parameter [31:0]  IP           = {8'd192, 8'd168, 8'd1, 8'd200},
   parameter [15:0]  UDP_PORT     = 16'd14500,
   parameter         TICKS_PER_US = 40,
   parameter         EVENT_GAP_US = 100
)
(
   input  wire          clk,
   input  wire          rst_n,

   input  wire          mii_rx_clk,
   input  wire          mii_rx_dv,
   input  wire          mii_rx_er,
   input  wire [3:0]    mii_rxd,
   input  wire          mii_tx_clk,
   output wire          mii_tx_en,
   output wire [3:0]    mii_txd,

   output wire [47:0]   ttlc_in,
   input  wire [47:0]   ttlc_out,
   input  wire          pmod_sel,

   output wire          rx_act,         // pulses: any frame, one for us, one sent
   output wire          accepted,
   output wire          tx_act
);

   wire           rx_valid;
   wire [10:0]    rx_len;
   wire [10:0]    rx_addr;
   wire [7:0]     rx_data;
   wire           rx_done;
   wire           tx_we;
   wire [10:0]    tx_addr;
   wire [7:0]     tx_data;
   wire           tx_start;
   wire [10:0]    tx_len;
   wire           tx_busy;

   wire           udp_rx_strobe;
   wire [7:0]     udp_rx_byte;
   wire           udp_rx_first;
   wire           udp_rx_last;
   wire [47:0]    udp_rx_src_mac;
   wire [31:0]    udp_rx_src_ip;
   wire [15:0]    udp_rx_src_port;
   wire           udp_tx_start;
   wire [10:0]    udp_tx_len;
   wire [10:0]    udp_tx_idx;
   wire [7:0]     udp_tx_byte;
   wire [47:0]    udp_tx_dst_mac;
   wire [31:0]    udp_tx_dst_ip;
   wire [15:0]    udp_tx_dst_port;
   wire           udp_tx_ready;

   eth_mii_mac mac
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
      .rx_valid   ( rx_valid   ),
      .rx_len     ( rx_len     ),
      .rx_addr    ( rx_addr    ),
      .rx_data    ( rx_data    ),
      .rx_done    ( rx_done    ),
      .tx_we      ( tx_we      ),
      .tx_addr    ( tx_addr    ),
      .tx_data    ( tx_data    ),
      .tx_start   ( tx_start   ),
      .tx_len     ( tx_len     ),
      .tx_busy    ( tx_busy    ),
      .rx_act     ( rx_act     ),
      .tx_act     ( tx_act     )
   );

   eth_ipstack #( .MAC(MAC), .IP(IP), .UDP_PORT(UDP_PORT) ) stack
   (
      .clk             ( clk             ),
      .rst_n           ( rst_n           ),
      .rx_valid        ( rx_valid        ),
      .rx_len          ( rx_len          ),
      .rx_addr         ( rx_addr         ),
      .rx_data         ( rx_data         ),
      .rx_done         ( rx_done         ),
      .tx_we           ( tx_we           ),
      .tx_addr         ( tx_addr         ),
      .tx_data         ( tx_data         ),
      .tx_start        ( tx_start        ),
      .tx_len          ( tx_len          ),
      .tx_busy         ( tx_busy         ),
      .udp_rx_strobe   ( udp_rx_strobe   ),
      .udp_rx_byte     ( udp_rx_byte     ),
      .udp_rx_first    ( udp_rx_first    ),
      .udp_rx_last     ( udp_rx_last     ),
      .udp_rx_src_mac  ( udp_rx_src_mac  ),
      .udp_rx_src_ip   ( udp_rx_src_ip   ),
      .udp_rx_src_port ( udp_rx_src_port ),
      .udp_tx_start    ( udp_tx_start    ),
      .udp_tx_len      ( udp_tx_len      ),
      .udp_tx_idx      ( udp_tx_idx      ),
      .udp_tx_byte     ( udp_tx_byte     ),
      .udp_tx_dst_mac  ( udp_tx_dst_mac  ),
      .udp_tx_dst_ip   ( udp_tx_dst_ip   ),
      .udp_tx_dst_port ( udp_tx_dst_port ),
      .udp_tx_ready    ( udp_tx_ready    ),
      .accepted        ( accepted        )
   );

   ttlc_eth_app #( .TICKS_PER_US(TICKS_PER_US), .EVENT_GAP_US(EVENT_GAP_US) ) app
   (
      .clk             ( clk             ),
      .rst_n           ( rst_n           ),
      .udp_rx_strobe   ( udp_rx_strobe   ),
      .udp_rx_byte     ( udp_rx_byte     ),
      .udp_rx_first    ( udp_rx_first    ),
      .udp_rx_last     ( udp_rx_last     ),
      .udp_rx_src_mac  ( udp_rx_src_mac  ),
      .udp_rx_src_ip   ( udp_rx_src_ip   ),
      .udp_rx_src_port ( udp_rx_src_port ),
      .udp_tx_start    ( udp_tx_start    ),
      .udp_tx_len      ( udp_tx_len      ),
      .udp_tx_idx      ( udp_tx_idx      ),
      .udp_tx_byte     ( udp_tx_byte     ),
      .udp_tx_dst_mac  ( udp_tx_dst_mac  ),
      .udp_tx_dst_ip   ( udp_tx_dst_ip   ),
      .udp_tx_dst_port ( udp_tx_dst_port ),
      .udp_tx_ready    ( udp_tx_ready    ),
      .ttlc_in         ( ttlc_in         ),
      .ttlc_out        ( ttlc_out        ),
      .pmod_sel        ( pmod_sel        )
   );

endmodule
