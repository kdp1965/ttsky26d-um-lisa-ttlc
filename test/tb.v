`default_nettype wire
`timescale 1ns / 1ps

/*
this testbench just instantiates the module and makes some convenient wires
that can be driven / tested by the cocotb test.py
*/

module tb
(
   // testbench is controlled by test.py (the clock runs here: 50 MHz)
   input  wire          rst_n,
   input  wire          ena,
   input  wire  [7:0]   tx_d,
   input  wire          tx_wr,
   output wire          tx_buf_empty,
   input  wire          rx_rd,
   output wire  [7:0]   rx_d,
   output wire          rx_avail,
   input  wire  [1:0]   uart_port_sel,
   input  wire  [7:0]   porta_in,
   input  wire  [13:0]  bitclks,            // the testbench UART's bit period in clocks
   output wire  [7:0]   porta_out,
   input  wire          ttlc_mode,          // ui_in[6:4] from the input chains
   input  wire  [47:0]  ttlc_in,            // the 48 inputs on the 74HC165 chains
   output wire  [47:0]  ttlc_out            // the 48 outputs on the 74HC595 chains
);
   wire     [2:0] ttlc_din;

   reg            clk = 1'b0;
   always #10 clk = ~clk;

   wire     [7:0] ui_in;
   wire     [7:0] uo_out;
   wire     [7:0] uio_oe;
   wire     [7:0] uio_out;
   wire     [7:0] uio_in;

   wire           ce0;
   wire           ce1;
   wire           sclk;
   wire           dq0;
   wire           dq1;
   wire           dq2;
   wire           dq3;

   wire           baud_ref;
   wire           txd;
   wire           rxd;

   // The fetch counts test.py reads with +STATS: the core's clocks, the
   // instructions it took and the clocks it waited for one; the QSPI
   // engine's transfers and the words they delivered (the instruction fetch
   // is nearly all of them when the data cache is off)
   reg [31:0] st_clocks = 0, st_insts = 0, st_wait = 0, st_xfers = 0, st_words = 0;
   reg        st_ready_r = 0;
   reg [3:0]  st_state_r = 0;
   always @(posedge clk)
   begin
      st_clocks  <= st_clocks + 1;
      if (lisa.core_i_fetch & lisa.core_i_ready) st_insts <= st_insts + 1;
      if (lisa.core_i_fetch & !lisa.core_i_ready) st_wait <= st_wait + 1;
      st_ready_r <= lisa.i_lisa_qqspi.ready;
      st_state_r <= lisa.i_lisa_qqspi.state;
      if (lisa.i_lisa_qqspi.ready & !st_ready_r) st_words <= st_words + 1;
      if (st_state_r == 4'd0 && lisa.i_lisa_qqspi.state == 4'd1) st_xfers <= st_xfers + 1;
   end

   initial begin
     if ($test$plusargs("DUMP"))
     begin
        $dumpfile("tb.vcd");
        $dumpvars(0, tb);
     end
     #1;
   end

   // ==========================================================================
   // instantiate the DUT
   // ==========================================================================
   tt_um_lisa lisa
   (
`ifdef GL_TEST
      .VPWR(1'b1),
      .VGND(1'b0),
`endif
      .ui_in   ( ui_in    ),
      .uo_out  ( uo_out   ),
      .uio_in  ( uio_in   ),
      .uio_out ( uio_out  ),
      .uio_oe  ( uio_oe   ),
      .ena     ( ena      ),
      .clk     ( clk      ),
      .rst_n   ( rst_n    )
   );

   // ==========================================================================
   // Connect the QSPI signals to the SPI flash
   // ==========================================================================
   //assign ce0  = uio_out[0];
   assign sclk = uio_out[3];
   assign dq0  = uio_oe[1] ? uio_out[1] : 1'bz;
   assign dq1  = uio_oe[2] ? uio_out[2] : 1'bz;
   assign dq2  = uio_oe[6] ? uio_out[6] : 1'bz;
   assign dq3  = uio_oe[7] ? uio_out[7] : 1'bz;
   assign uio_in[0] = 1'b0;
   assign uio_in[1] = dq0;
   assign uio_in[2] = dq1;
   assign uio_in[5:3] = 3'b0;
   assign uio_in[6] = uart_port_sel == 2'h2 ? txd : dq2;
   assign uio_in[7] = dq3;

   pullup (dq0);
   pullup (dq1);
   pullup (dq2);
   pullup (dq3);

   // ==========================================================================
   // The chip selects: plain SPI pins (io mux 0x1c bits 1:0 = 3 puts CE1 on
   // uio[4]); the TT07 testbench modelled the custom Pmod's CE latches here
   // ==========================================================================
   assign ce0 = uio_out[0];
   assign ce1 = uio_out[4];

   // ==========================================================================
   // Connect the UART to the port specified
   // ==========================================================================
   assign ui_in[3]  = uart_port_sel == 2'h0 ? txd : porta_in[3];
   assign uio_in[4] = uart_port_sel == 2'h1 ? txd : 1'b0;
   assign rxd = uart_port_sel == 2'h0 ? uo_out[4] : 
                uart_port_sel == 2'h1 ? uio_out[5] :
                uart_port_sel == 2'h2 ? uio_out[5] :
                1'b0;

   // ==========================================================================
   // Create a testbench UART to interface with the design
   // ==========================================================================
   lisa_tx8n i_tx8n
   (
      .clk        ( clk          ),
      .rst_n      ( rst_n        ),
      .baud_ref   ( baud_ref     ),  // Baud Rate reference
      .wr         ( tx_wr        ),  // Write signal
      .d          ( tx_d         ),  // Input data
      .txd        ( txd          ),  // Output serial data
      .buf_empty  ( tx_buf_empty )
   );

   lisa_rx8n i_rx8n
   (
      .clk        ( clk          ),
      .rst_n      ( rst_n        ),
      .baud_ref   ( baud_ref     ),
      .rxd        ( rxd          ),
      .rd         ( rx_rd        ),
      .d          ( rx_d         ),
      .data_avail ( rx_avail     ),
       .rx_strobe  (              ),
       .rx_byte    (              ),
       .overrun    (              )
   );

   // the period is taken on the clock after reset (bitclks is set before)
   reg            bit_wr;
   always @(posedge clk)
      bit_wr <= rst_n;
   debug_brg i_brg
   (
      // Timing and reset inputs
      .clk        ( clk          ),       // System clock
      .rst_n      ( rst_n        ),       // Active low reset
      .wr         ( bit_wr       ),       // Data write strobe
      .d          ( bitclks      ),       // the bit period in clocks
      .baud_set   ( 1'b0         ),
      .baud_div   ( 7'd0         ),
      .baud_ref   ( baud_ref     )
   );

   // ==========================================================================
   // Assign the port I/O; with ttlc_mode the input chains drive ui_in[6:4]
   // ==========================================================================
   assign porta_out = uo_out;
   assign ui_in[2:0] = porta_in[2:0];
   assign ui_in[7]   = porta_in[7];
   assign ui_in[6:4] = ttlc_mode ? ttlc_din : porta_in[6:4];

   // ==========================================================================
   // The TTLC's I/O Pmod: three 74HC595 chains (16 outputs each: data on
   // uo_out[2:0], shift clock uo_out[6], the output latch on uo_out[5]'s
   // rising edge) and three 74HC165 chains (16 inputs each, loaded while
   // the latch is low, the serial output into ui_in[6:4])
   // ==========================================================================
   ttlc_chains i_chains
   (
      .sclk    ( uo_out[6]    ),
      .latch   ( uo_out[5]    ),
      .dout    ( uo_out[2:0]  ),
      .din     ( ttlc_din     ),
      .inputs  ( ttlc_in      ),
      .outputs ( ttlc_out     )
   );
   
   // ==========================================================================
   // Instantiate a SPI flash
   // ==========================================================================
   spiflash
   #(
      .FILENAME("firmware.hex")  // change the hex file to match your project
   )
   spiflash
   (
      .csb  ( ce0                  ),
      .clk  ( sclk                 ),
      .io0  ( dq0                  ),
      .io1  ( dq1                  ),
      .io2  ( dq2                  ),
      .io3  ( dq3                  )
   );

   // ==========================================================================
   // Instantiate a SPI SRAM
   // ==========================================================================
   psram psram_I
   (
      .ce_n ( ce1                  ),
      .sck  ( sclk                 ),
      .dio  ( {dq3, dq2, dq1, dq0} )
   );
   //assign ce1 = 1'b1;

endmodule



// The 74HC595 / 74HC165 chains of the TTLC Pmod, 16 stages each.
module ttlc_chains
(
   input  wire          sclk,
   input  wire          latch,
   input  wire [2:0]    dout,          // into the 595 chains
   output wire [2:0]    din,           // out of the 165 chains
   input  wire [47:0]   inputs,
   output reg  [47:0]   outputs
);
   reg [15:0] sr595[0:2];
   reg [15:0] sr165[0:2];
   integer    k;
   initial
   begin
      outputs = 48'h0;
      for (k = 0; k < 3; k = k + 1)
      begin
         sr595[k] = 16'h0;
         sr165[k] = 16'h0;
      end
   end
   // 595: shift on the rising edge, the first bit in ends up at stage 15
   always @(posedge sclk)
      for (k = 0; k < 3; k = k + 1)
         sr595[k] <= {sr595[k][14:0], dout[k]};
   // the outputs latch on the rising edge of the latch pin
   always @(posedge latch)
      outputs <= {sr595[2], sr595[1], sr595[0]};
   // 165: parallel load while the latch (/PL) is low, else shift on the rising
   // edge; the serial output is stage 15
   always @(posedge sclk or negedge latch)
      if (!latch)
      begin
         sr165[0] <= inputs[15:0];
         sr165[1] <= inputs[31:16];
         sr165[2] <= inputs[47:32];
      end
      else
         for (k = 0; k < 3; k = k + 1)
            sr165[k] <= {sr165[k][14:0], 1'b0};
   assign din = {sr165[2][15], sr165[1][15], sr165[0][15]};
endmodule
