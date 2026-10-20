## LISA on the Arty A7-35T (lisa_arty.v); pins from Digilent's
## Arty-A7-35-Master.xdc.

## 100 MHz oscillator
set_property -dict { PACKAGE_PIN E3    IOSTANDARD LVCMOS33 } [get_ports { CLK100MHZ }];
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports { CLK100MHZ }];

## RESET button (active low, pulled up on the board)
set_property -dict { PACKAGE_PIN C2    IOSTANDARD LVCMOS33 } [get_ports { ck_rst }];

## Switches (SW3 up: the TTLC Pmod on JA / JB instead of the inside chains)
set_property -dict { PACKAGE_PIN A8    IOSTANDARD LVCMOS33 } [get_ports { sw[0] }];
set_property -dict { PACKAGE_PIN C11   IOSTANDARD LVCMOS33 } [get_ports { sw[1] }];
set_property -dict { PACKAGE_PIN C10   IOSTANDARD LVCMOS33 } [get_ports { sw[2] }];
set_property -dict { PACKAGE_PIN A10   IOSTANDARD LVCMOS33 } [get_ports { sw[3] }];

## LEDs LD4-LD7
set_property -dict { PACKAGE_PIN H5    IOSTANDARD LVCMOS33 } [get_ports { led[0] }];
set_property -dict { PACKAGE_PIN J5    IOSTANDARD LVCMOS33 } [get_ports { led[1] }];
set_property -dict { PACKAGE_PIN T9    IOSTANDARD LVCMOS33 } [get_ports { led[2] }];
set_property -dict { PACKAGE_PIN T10   IOSTANDARD LVCMOS33 } [get_ports { led[3] }];

## LD0 (RGB): Ethernet activity
set_property -dict { PACKAGE_PIN G6    IOSTANDARD LVCMOS33 } [get_ports { led0_r }];
set_property -dict { PACKAGE_PIN F6    IOSTANDARD LVCMOS33 } [get_ports { led0_g }];
set_property -dict { PACKAGE_PIN E1    IOSTANDARD LVCMOS33 } [get_ports { led0_b }];

## Pmod JA: ui_in (pulled down like the demo board drives them; ja[3] is
## the UART rx when SW0 selects it, idle high)
set_property -dict { PACKAGE_PIN G13   IOSTANDARD LVCMOS33 } [get_ports { ja[0] }];
set_property -dict { PACKAGE_PIN B11   IOSTANDARD LVCMOS33 } [get_ports { ja[1] }];
set_property -dict { PACKAGE_PIN A11   IOSTANDARD LVCMOS33 } [get_ports { ja[2] }];
set_property -dict { PACKAGE_PIN D12   IOSTANDARD LVCMOS33 } [get_ports { ja[3] }];
set_property -dict { PACKAGE_PIN D13   IOSTANDARD LVCMOS33 } [get_ports { ja[4] }];
set_property -dict { PACKAGE_PIN B18   IOSTANDARD LVCMOS33 } [get_ports { ja[5] }];
set_property -dict { PACKAGE_PIN A18   IOSTANDARD LVCMOS33 } [get_ports { ja[6] }];
set_property -dict { PACKAGE_PIN K16   IOSTANDARD LVCMOS33 } [get_ports { ja[7] }];
set_property PULLDOWN true [get_ports { ja[0] ja[1] ja[2] ja[4] ja[5] ja[6] ja[7] }];
set_property PULLUP   true [get_ports { ja[3] }];

## Pmod JB: uo_out
set_property -dict { PACKAGE_PIN E15   IOSTANDARD LVCMOS33 } [get_ports { jb[0] }];
set_property -dict { PACKAGE_PIN E16   IOSTANDARD LVCMOS33 } [get_ports { jb[1] }];
set_property -dict { PACKAGE_PIN D15   IOSTANDARD LVCMOS33 } [get_ports { jb[2] }];
set_property -dict { PACKAGE_PIN C15   IOSTANDARD LVCMOS33 } [get_ports { jb[3] }];
set_property -dict { PACKAGE_PIN J17   IOSTANDARD LVCMOS33 } [get_ports { jb[4] }];
set_property -dict { PACKAGE_PIN J18   IOSTANDARD LVCMOS33 } [get_ports { jb[5] }];
set_property -dict { PACKAGE_PIN K15   IOSTANDARD LVCMOS33 } [get_ports { jb[6] }];
set_property -dict { PACKAGE_PIN J15   IOSTANDARD LVCMOS33 } [get_ports { jb[7] }];

## Pmod JC: uio (the QSPI Pmod)
set_property -dict { PACKAGE_PIN U12   IOSTANDARD LVCMOS33 } [get_ports { jc[0] }];
set_property -dict { PACKAGE_PIN V12   IOSTANDARD LVCMOS33 } [get_ports { jc[1] }];
set_property -dict { PACKAGE_PIN V10   IOSTANDARD LVCMOS33 } [get_ports { jc[2] }];
set_property -dict { PACKAGE_PIN V11   IOSTANDARD LVCMOS33 } [get_ports { jc[3] }];
set_property -dict { PACKAGE_PIN U14   IOSTANDARD LVCMOS33 } [get_ports { jc[4] }];
set_property -dict { PACKAGE_PIN V14   IOSTANDARD LVCMOS33 } [get_ports { jc[5] }];
set_property -dict { PACKAGE_PIN T13   IOSTANDARD LVCMOS33 } [get_ports { jc[6] }];
set_property -dict { PACKAGE_PIN U13   IOSTANDARD LVCMOS33 } [get_ports { jc[7] }];
## uio[4..7] are inputs or open-drain until a program sets the uio mux
## (0x1c).  On the Tiny Tapeout QSPI Pmod they are the flash's WP# / HOLD#
## (SD2 / SD3) and the two PSRAMs' selects, which must idle high or the
## flash holds and the PSRAMs drive MISO; uio[4] and uio[6] are also the
## debug UART's other rx candidates, idle high like a UART
set_property PULLUP true [get_ports { jc[4] jc[5] jc[6] jc[7] }];

## USB-UART (FTDI): uart_txd_in is the host's transmit, into the design
set_property -dict { PACKAGE_PIN D10   IOSTANDARD LVCMOS33 } [get_ports { uart_rxd_out }];
set_property -dict { PACKAGE_PIN A9    IOSTANDARD LVCMOS33 } [get_ports { uart_txd_in }];

## Ethernet PHY (DP83848J, MII).  The PHY's RX_CLK and TX_CLK are 25 MHz
## (2.5 MHz at 10 Mb/s); the design's three clocks are asynchronous to
## each other (eth_mii_mac.v synchronizes).  RXD / RX_DV / RX_ER change
## 10 to 30 ns after RX_CLK rises; TXD / TX_EN need 10 ns of setup and
## none of hold at the PHY.
set_property -dict { PACKAGE_PIN G18   IOSTANDARD LVCMOS33 } [get_ports { eth_ref_clk }];
set_property -dict { PACKAGE_PIN C16   IOSTANDARD LVCMOS33 } [get_ports { eth_rstn }];
set_property -dict { PACKAGE_PIN F15   IOSTANDARD LVCMOS33 } [get_ports { eth_rx_clk }];
set_property -dict { PACKAGE_PIN G16   IOSTANDARD LVCMOS33 } [get_ports { eth_rx_dv }];
set_property -dict { PACKAGE_PIN D18   IOSTANDARD LVCMOS33 } [get_ports { eth_rxd[0] }];
set_property -dict { PACKAGE_PIN E17   IOSTANDARD LVCMOS33 } [get_ports { eth_rxd[1] }];
set_property -dict { PACKAGE_PIN E18   IOSTANDARD LVCMOS33 } [get_ports { eth_rxd[2] }];
set_property -dict { PACKAGE_PIN G17   IOSTANDARD LVCMOS33 } [get_ports { eth_rxd[3] }];
set_property -dict { PACKAGE_PIN C17   IOSTANDARD LVCMOS33 } [get_ports { eth_rxerr }];
set_property -dict { PACKAGE_PIN H16   IOSTANDARD LVCMOS33 } [get_ports { eth_tx_clk }];
set_property -dict { PACKAGE_PIN H15   IOSTANDARD LVCMOS33 } [get_ports { eth_tx_en }];
set_property -dict { PACKAGE_PIN H14   IOSTANDARD LVCMOS33 } [get_ports { eth_txd[0] }];
set_property -dict { PACKAGE_PIN J14   IOSTANDARD LVCMOS33 } [get_ports { eth_txd[1] }];
set_property -dict { PACKAGE_PIN J13   IOSTANDARD LVCMOS33 } [get_ports { eth_txd[2] }];
set_property -dict { PACKAGE_PIN H17   IOSTANDARD LVCMOS33 } [get_ports { eth_txd[3] }];
create_clock -add -name eth_rx_clk -period 40.00 [get_ports { eth_rx_clk }];
create_clock -add -name eth_tx_clk -period 40.00 [get_ports { eth_tx_clk }];
set_clock_groups -asynchronous -group [get_clocks -include_generated_clocks sys_clk_pin] \
                               -group [get_clocks eth_rx_clk] -group [get_clocks eth_tx_clk];
set_input_delay  -clock eth_rx_clk -max 30.0 [get_ports { eth_rxd[*] eth_rx_dv eth_rxerr }];
set_input_delay  -clock eth_rx_clk -min 10.0 [get_ports { eth_rxd[*] eth_rx_dv eth_rxerr }];
set_output_delay -clock eth_tx_clk -max 10.0 [get_ports { eth_txd[*] eth_tx_en }];
set_output_delay -clock eth_tx_clk -min  0.0 [get_ports { eth_txd[*] eth_tx_en }];

## Everything else off chip is asynchronous to the project clock
set_false_path -from [get_ports { ck_rst sw[*] ja[*] jc[*] uart_txd_in }];
set_false_path -to   [get_ports { led[*] led0_* jb[*] jc[*] uart_rxd_out eth_rstn }];

## Configuration
set_property CFGBVS VCCO [current_design];
set_property CONFIG_VOLTAGE 3.3 [current_design];

# Keep the instruction stream's boundary: lisa_arty_mcp.tcl's exception for
# the fetch select runs -through its core_i_ready output, which synthesis
# otherwise folds into the core's instruction mux (it did with the rev-3 RTL,
# and the net was gone).  A synthesis property, read before synth_design.
set_property KEEP_HIERARCHY yes [get_cells lisa/i_inst_stream]
