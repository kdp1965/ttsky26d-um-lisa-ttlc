/*
==============================================================================
lisa_periph.v:  Little ISA (LISA) peripherals.

Copyright 2024 by Ken Pettit <pettitkd@gmail.com>

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

==============================================================================
*/

`define TIMER2
`define WANT_UART2

/*
==========================================================================================
lisa_periph:   A peripheral controller for the lisa core.

Address Map:

   GPIO
   ====
   0x00:       PORT A input
   0x01:       PORT B output
   0x02:       PORT C input / output
   0x03:       PORT C direction (1 = output)
   0x04:       PORT D input   (from TTLC)
   0x05:       PORT E output  (to TTLC)
   0x06:       PORT A INT_CFG0
   0x07:       PORT A INT_CFG1

   TIMER
   =====
   0x08:       Pre Divisor Low
   0x09:       Pre Divisor High
   0x0A:       Divisor Low
   0x0B:       Divisor High
   0x0C:       Control / Status
   0x0D:       Timer tick

   Interrupt
   =========
   0x0E:       Interrupt Enable Register
   0x0F:       Interrupt Status/ACK Register

   UART
   ====
   0x10:       TX/RX register
   0x11:       Status register: bit 0 RX data available, 1 TX buffer empty,
               2 RX overrun (a byte arrived with the 8-byte FIFO full; sticky until it is read empty)
   0x12:       UART2 TX/RX register
   0x13:       UART2 status: bits 0-1 as 0x11, 2 autobaud disable (r/w), 3 RX overrun
   0x1E:       UART2 baud divisor (write): a bit is 32 x (d + 1) clocks
   0x14:       UART interrupt enables

   BANKS (revision 2, RESPIN 22)
   =============================
   0x15:       Code bank  [5:0]: fetches above word 0x4000             (reset 1)
   0x16:       Data bank  [3:0]: IX-relative and debugger accesses above 0x4000 (reset 1)
   0x17:       Stack bank [3:0]: SP-relative accesses above 0x4000     (reset 1)

   TIMER2
   =====
   0x18:       Pre Divisor Low
   0x19:       Pre Divisor High
   0x1A:       Divisor Low
   0x1B:       Divisor High
   0x1C:       Control / Status
   0x1D:       Timer tick

   I2C
   ====
   0x20:       CLOCK PRE div LSB register
   0x21:       CLOCK PRE div MSB register
   0x22:       CTRL
   0x23:       RX
   0x24:       STATUS
   0x25:       TX
   0x26:       CMD

==========================================================================================
*/
module lisa_periph
(
   input                clk,
   input                rst_n,
`ifdef WANT_UART2
   input                rst_async_n,
`endif

   // UART access
   input  [6:0]         d_addr,
   input  [7:0]         d_i,
   input                d_periph,
   input                d_we,
   input                d_rd,
   output wire [7:0]    d_o,

   // GPIO
   input  wire [7:0]    porta_in,
   output reg  [7:0]    portb,
   output reg  [3:0]    portc,
   input  wire [3:0]    portc_in,
   output reg  [3:0]    portc_dir,
   input  wire [7:0]    portd_in,
   output reg  [7:0]    porte,

   // The bank registers (RESPIN 22)
   output reg  [5:0]    code_bank,          // 6 bits: 64 code banks of 16K words (1M words)
   output reg  [3:0]    data_bank,
   output reg  [3:0]    stack_bank,

   output wire [7:0]    int_o,
   output reg  [7:0]    int_en,
   input  wire          ttlc_int,

   // UART
   output wire [7:0]    uart_tx_d,
   output wire          uart_tx_wr,
   output wire          uart_rx_rd,
   input  wire [7:0]    uart_rx_d,
   input  wire          uart_rx_data_avail,
   input  wire          uart_tx_buf_empty,
   input  wire          uart_rx_overrun,

`ifdef WANT_UART2
   // UART 2
   input  wire          uart2_rx,
   output wire          uart2_tx,
`endif

   // I2C
   input  wire          scl_pad_i,
   output wire          scl_pad_o,
   output wire          scl_padoen_o,
   input  wire          sda_pad_i,
   output wire          sda_pad_o,
   output wire          sda_padoen_o
);

   reg   [15:0]         ms_count;
   reg   [15:0]         ms_prediv;
   reg   [15:0]         ms_preload;
   reg   [15:0]         ms_timer;
   reg   [7:0]          ms_tick;
   reg                  ms_enable;
   reg                  ms_rollover;
   reg                  uart_tx_ie;
   reg                  uart_rx_ie;
   reg                  uart_rx_data_avail_p1;
   reg                  uart_tx_buf_empty_p1;
   
   reg   [5:0]          int_o_r;
   reg   [7:0]          porta_last;
   reg   [7:0]          porta_int0;
   reg   [7:0]          porta_int1;
   wire  [1:0]          porta_int_mode[7:0];
   reg   [7:0]          porta_int;
   reg                  ttlc_int_last;

`ifdef TIMER2
   reg   [15:0]         ms2_count;
   reg   [15:0]         ms2_prediv;
   reg   [15:0]         ms2_preload;
   reg   [15:0]         ms2_timer;
   reg   [7:0]          ms2_tick;
   reg                  ms2_enable;
   reg                  ms2_rollover;
`endif

   wire  [3:0]          portc_read;
   reg   [7:0]          d_o_r;
   wire  [7:0]          i2c_d_o;
   wire                 sda_oen_n;
   wire                 scl_oen_n;
   wire                 i2c_irq;

`ifdef WANT_UART2
   // UART
   wire [7:0]    uart2_tx_d;
   wire          uart2_tx_wr;
   wire          uart2_rx_rd;
   wire [7:0]    uart2_rx_d;
   wire          uart2_rx_data_avail;
   wire          uart2_tx_buf_empty;
   wire          uart2_rx_overrun;
   wire          uart2_brg_wr;
   wire [7:0]    uart2_brg_d;
   reg           uart2_autobaud_disable;
   reg           uart2_tx_ie;
   reg           uart2_rx_ie;
   reg           uart2_rx_data_avail_p1;
   reg           uart2_tx_buf_empty_p1;
`endif

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         porta_last   <= 8'h00;
         porta_int0   <= 8'h00;
         porta_int1   <= 8'h00;
         portb        <= 8'h00;
         portc        <= 4'h00;
         porte        <= 8'h00;
         portc_dir    <= 4'h0;
         code_bank    <= 6'h1;
         data_bank    <= 4'h1;
         stack_bank   <= 4'h1;
         ms_prediv    <= 16'd29494;
         ms_count     <= 16'h0;
         ms_timer     <= 16'h0;
         ms_preload   <= 16'h0;
         ms_tick      <= 8'h0;
         ms_enable    <= 1'h0;
         ms_rollover  <= 1'b0;
         int_o_r      <= 6'h0;
         int_en       <= 8'h0;
         uart_tx_ie   <= 1'b0;
         uart_rx_ie   <= 1'b0;
         uart_rx_data_avail_p1 <= 1'b0;
         uart_tx_buf_empty_p1 <= 1'b0;

`ifdef TIMER2
         ms2_prediv   <= 16'd29494;
         ms2_count    <= 16'h0;
         ms2_timer    <= 16'h0;
         ms2_preload  <= 16'h0;
         ms2_tick     <= 8'h0;
         ms2_enable   <= 1'h0;
         ms2_rollover <= 1'b0;
`endif
`ifdef WANT_UART2
         uart2_autobaud_disable <= 1'b0;
         uart2_tx_ie  <= 1'b0;
         uart2_rx_ie  <= 1'b0;
         uart2_rx_data_avail_p1 <= 1'b0;
         uart2_tx_buf_empty_p1 <= 1'b0;
`endif
      end
      else
      begin
         porta_last <= porta_in;
         ttlc_int_last <= ttlc_int;
         uart_rx_data_avail_p1 <= uart_rx_data_avail;
         uart_tx_buf_empty_p1 <= uart_tx_buf_empty;
`ifdef WANT_UART2
         uart2_rx_data_avail_p1 <= uart2_rx_data_avail;
         uart2_tx_buf_empty_p1 <= uart2_tx_buf_empty;
`endif

         // ==============================================
         // GPIO signals
         // ==============================================
         // Latch input data as PORTB
         if (d_periph && d_we && d_addr == 7'h01)
            portb <= d_i;

         // Latch input data as PORTC
         if (d_periph && d_we && d_addr == 7'h02)
            portc <= d_i[3:0];

         // Latch input data as PORTC_DIR
         if (d_periph && d_we && d_addr == 7'h03)
            portc_dir <= d_i[3:0];

         // Latch porte
         if (d_periph && d_we && d_addr == 7'h05)
            porte <= d_i;

         // The bank registers: code (fetches above word 0x4000), data
         // (IX-relative and debugger accesses above 0x4000) and stack
         // (SP-relative accesses above 0x4000).  1 = the upper half as the
         // TT07 chip had it, so an image that never writes them runs as before
         if (d_periph && d_we && d_addr == 7'h15)
            code_bank <= d_i[5:0];
         if (d_periph && d_we && d_addr == 7'h16)
            data_bank <= d_i[3:0];
         if (d_periph && d_we && d_addr == 7'h17)
            stack_bank <= d_i[3:0];

         // Latch porta_int0
         if (d_periph && d_we && d_addr == 7'h06)
            porta_int0 <= d_i;

         // Latch porta_int1
         if (d_periph && d_we && d_addr == 7'h07)
            porta_int1 <= d_i;

         // GPIO Interrupt
         if (|porta_int)
            int_o_r[4] <= 1'b1;
         else if (d_periph && d_we && d_addr == 7'h0F && d_i[4])
            int_o_r[4] <= 1'b0;

         // TTLC Interrupt
         if (ttlc_int ^ ttlc_int_last)
            int_o_r[5] <= 1'b1;
         else if (d_periph && d_we && d_addr == 7'h0F && d_i[5])
            int_o_r[5] <= 1'b0;

         // ==============================================
         // Interrupt enable
         // ==============================================
         if (d_periph && d_we && d_addr == 7'h0E)
            int_en <= d_i;

         // ==============================================
         // Timer signals
         // ==============================================
         // The control signal
         if (d_periph && d_we && d_addr == 7'h0C)
            ms_enable <= d_i[0];

         // The pre divider
         if (d_periph && d_we && d_addr == 7'h08)
            ms_prediv[7:0] <= d_i;

         // The pre divider
         if (d_periph && d_we && d_addr == 7'h09)
            ms_prediv[15:8] <= d_i;

         // The preload
         if (d_periph && d_we && d_addr == 7'h0A)
            ms_preload[7:0] <= d_i;

         // The preload
         if (d_periph && d_we && d_addr == 7'h0B)
            ms_preload[15:8] <= d_i;

         // The ms_rollover bit
         if (d_periph && 
                ((d_rd && d_addr == 7'h0C) ||
                 (d_we && d_addr == 7'h0D)))
            ms_rollover <= 1'b0;
         else if (ms_count == ms_prediv && ms_timer == 16'h01)
         begin
            ms_rollover <= 1'b1;
            int_o_r[0] <= 1'b1;
         end
         else if (d_periph && d_we && d_addr == 7'h0F && d_i[0])
            int_o_r[0] <= 1'b0;

         // Loading tick value also resets 1ms timimg
         if (d_periph && d_we && d_addr == 7'h0D)
         begin
            ms_tick <= d_i;
            ms_timer <= ms_preload;
            ms_count <= 16'h0; 
         end

         // Test if timer is enabled
         else if (ms_enable)
         begin
            // Implement a 1ms tick
            if (ms_count == ms_prediv)
            begin
               ms_count <= 16'h0; 
            
               // Count down to 1 then increment tick and load the preload
               if (ms_timer == 16'h01)
               begin
                  ms_tick <= ms_tick + 1;
                  ms_timer <= ms_preload;
               end
               else
                  ms_timer <= ms_timer - 1;
            end
            else
               ms_count <= ms_count + 16'h1;
         end
         else
         begin
            ms_tick <= 8'h0;
            ms_timer <= ms_preload;
            ms_count <= 16'h0; 
         end

         // ==============================================
         // The UART interrupt bits
         // ==============================================
         if ((uart_rx_data_avail & !uart_rx_data_avail_p1 & uart_rx_ie) ||
             (uart_tx_buf_empty & !uart_tx_buf_empty_p1 & uart_tx_ie))
         begin
            int_o_r[2] <= 1'b1;
         end
         else if (d_periph && d_we && d_addr == 7'h0F && d_i[2])
            int_o_r[2] <= 1'b0;

`ifdef TIMER2
         // ==============================================
         // Timer2 signals
         // ==============================================
         // The control signal
         if (d_periph && d_we && d_addr == 7'h1C)
            ms2_enable <= d_i[0];

         // The pre divider
         if (d_periph && d_we && d_addr == 7'h18)
            ms2_prediv[7:0] <= d_i;

         // The pre divider
         if (d_periph && d_we && d_addr == 7'h19)
            ms2_prediv[15:8] <= d_i;

         // The preload
         if (d_periph && d_we && d_addr == 7'h1A)
            ms2_preload[7:0] <= d_i;

         // The preload
         if (d_periph && d_we && d_addr == 7'h1B)
            ms2_preload[15:8] <= d_i;

         // The ms2_rollover bit
         if (d_periph && 
                ((d_rd && d_addr == 7'h1C) ||
                 (d_we && d_addr == 7'h1D)))
            ms2_rollover <= 1'b0;
         else if (ms2_count == ms2_prediv && ms2_timer == 16'h01)
         begin
            ms2_rollover <= 1'b1;
            int_o_r[1] <= 1'b1;
         end
         else if (d_periph && d_we && d_addr == 7'h0F && d_i[1])
            int_o_r[1] <= 1'b0;

         // Loading tick value also resets 1ms timimg
         if (d_periph && d_we && d_addr == 7'h1D)
         begin
            ms2_tick <= d_i;
            ms2_timer <= ms2_preload;
            ms2_count <= 16'h0; 
         end

         // Test if timer is enabled
         else if (ms2_enable)
         begin
            // Implement a 1ms tick
            if (ms2_count == ms2_prediv)
            begin
               ms2_count <= 16'h0; 
            
               // Count down to 1 then increment tick and load the preload
               if (ms2_timer == 16'h01)
               begin
                  ms2_tick <= ms2_tick + 1;
                  ms2_timer <= ms2_preload;
               end
               else
                  ms2_timer <= ms2_timer - 1;
            end
            else
               ms2_count <= ms2_count + 16'h1;
         end
         else
         begin
            ms2_tick <= 8'h0;
            ms2_timer <= ms2_preload;
            ms2_count <= 16'h0; 
         end
`endif
`ifdef WANT_UART2
         // UART2 autobaud disable
         if (d_periph && d_we && d_addr == 7'h13)
            uart2_autobaud_disable <= d_i[2];

         // ==============================================
         // The UART2 interrupt bits
         // ==============================================
         if ((uart2_rx_data_avail & !uart2_rx_data_avail_p1 & uart2_rx_ie) ||
             (uart2_tx_buf_empty & !uart2_tx_buf_empty_p1 & uart2_tx_ie))
         begin
            int_o_r[3] <= 1'b1;
         end
         else if (d_periph && d_we && d_addr == 7'h0F && d_i[3])
            int_o_r[3] <= 1'b0;
`endif
      end
   end

   // ==============================================
   // The read signals
   // ==============================================
   generate
   genvar x;
   for (x = 0; x < 4; x = x + 1)
   begin : GEN_READ
      assign portc_read[x] = portc_dir[x] ? portc[x] : portc_in[x];
   end

   // PORTA interrupt signals
   for (x = 0; x < 8; x = x + 1)
   begin : GEN_INT
      assign porta_int_mode[x][0] = porta_int0[x];
      assign porta_int_mode[x][1] = porta_int1[x];

      always @*
      case (porta_int_mode[x])
      2'h0: porta_int[x] = 1'b0;
      2'h1: porta_int[x] = porta_in[x];
      2'h2: porta_int[x] = porta_in[x] & !porta_last[x];
      2'h3: porta_int[x] = ~porta_in[x] & porta_last[x];
      endcase
   end
   endgenerate 

   always @*
   begin
      case (d_addr)
      // GPIO readback
      7'h00:   d_o_r = porta_in;
      7'h01:   d_o_r = portb;
      7'h02:   d_o_r = {4'h0, portc_read};
      7'h03:   d_o_r = {4'h0, portc_dir};
      7'h04:   d_o_r = portd_in;
      7'h05:   d_o_r = porte;
      7'h06:   d_o_r = porta_int0;
      7'h07:   d_o_r = porta_int1;

      // Timer readback
      7'h08:   d_o_r = ms_prediv[7:0];
      7'h09:   d_o_r = ms_prediv[15:8];
      7'h0A:   d_o_r = ms_preload[7:0];
      7'h0B:   d_o_r = ms_preload[15:8];
      7'h0C:   d_o_r = { ms_rollover, 6'h0, ms_enable};
      7'h0D:   d_o_r = ms_tick;

      // Int EN readback
      7'h0E:   d_o_r = int_en;
      7'h0F:   d_o_r = {1'h0, i2c_irq, int_o_r};

      // UART read
      7'h10:   d_o_r = uart_rx_d;
      // bit 2 (RESPIN 14): a byte arrived with the 8-byte receive FIFO full;
      // clears when the FIFO has been read empty
      7'h11:   d_o_r = {5'h0, uart_rx_overrun, uart_tx_buf_empty, uart_rx_data_avail};

`ifdef WANT_UART2
      // UART2 read
      7'h12:   d_o_r = uart2_rx_d;
      7'h13:   d_o_r = {4'h0, uart2_rx_overrun, uart2_autobaud_disable, uart2_tx_buf_empty, uart2_rx_data_avail};
      7'h14:   d_o_r = {4'h0, uart2_tx_ie, uart2_rx_ie, uart_tx_ie, uart_rx_ie};
`else
      7'h14:   d_o_r = {6'h0, uart_tx_ie, uart_rx_ie};
`endif

      // Bank registers
      7'h15:   d_o_r = {2'h0, code_bank};
      7'h16:   d_o_r = {4'h0, data_bank};
      7'h17:   d_o_r = {4'h0, stack_bank};

      // Timer2 readback
`ifdef TIMER2
      7'h18:   d_o_r = ms2_prediv[7:0];
      7'h19:   d_o_r = ms2_prediv[15:8];
      7'h1A:   d_o_r = ms2_preload[7:0];
      7'h1B:   d_o_r = ms2_preload[15:8];
      7'h1C:   d_o_r = { ms2_rollover, 6'h0, ms2_enable};
      7'h1D:   d_o_r = ms2_tick;
`endif

      default: d_o_r = 8'h00;
      endcase
   end

   // ==============================================
   // UART read / write controls
   // ==============================================
   // d_rd is the core's read strobe (lda, swapi: RESPIN 23 - on TT07 a store's
   // exec clock pulsed it too, and a putc to 0x10 popped a received byte)
   assign uart_tx_wr = d_periph && d_we && d_addr == 7'h10;
   assign uart_rx_rd = d_periph && d_rd && d_addr == 7'h10;
   assign uart_tx_d  = d_i;

`ifdef WANT_UART2
   assign uart2_tx_wr = d_periph && d_we && d_addr == 7'h12;
   assign uart2_rx_rd = d_periph && d_rd && d_addr == 7'h12;
   assign uart2_tx_d  = d_i;
   // UART2's baud divisor: a bit is 32 x (d + 1) clocks (as the debug BRG);
   // it was written by any access to 0x14, the interrupt enables (RESPIN 23)
   assign uart2_brg_wr= d_periph && d_we && d_addr == 7'h1E;
   assign uart2_brg_d = d_i;
`endif

   // ==============================================
   // Instantiate I2C master
   // ==============================================
   lisa_i2c i_lisa_i2c
   (
      .clk          ( clk          ),
      .rst_n        ( rst_n        ),
      .d_addr       ( d_addr       ),
      .d_i          ( d_i          ),
      .d_periph     ( d_periph     ),
      .d_we         ( d_we         ),
      .d_o          ( i2c_d_o      ),
      .scl_pad_i    ( scl_pad_i    ),
      .scl_pad_o    ( scl_pad_o    ),
      .scl_padoen_o ( scl_oen_n    ),
      .sda_pad_i    ( sda_pad_i    ),
      .sda_pad_o    ( sda_pad_o    ),
      .sda_padoen_o ( sda_oen_n    ),
      .irq_flag     ( i2c_irq      )
   );
   assign scl_padoen_o  = ~scl_oen_n;
   assign sda_padoen_o  = ~sda_oen_n;

   assign d_o = d_o_r | i2c_d_o;
   assign int_o = {1'h0, i2c_irq, int_o_r};

`ifdef WANT_UART2
   lisa_uart i_lisa_uart_2
   (
      .clk              ( clk                    ),
      .rst_n            ( rst_n                  ),
      .rst_async_n      ( rst_async_n            ),
      .rx               ( uart2_rx               ),
      .tx               ( uart2_tx               ),
      .tx_d             ( uart2_tx_d             ),
      .tx_wr            ( uart2_tx_wr            ),
      .rx_rd            ( uart2_rx_rd            ),
      .rx_d             ( uart2_rx_d             ),
      .rx_data_avail    ( uart2_rx_data_avail    ),
      .tx_buf_empty     ( uart2_tx_buf_empty     ),
      .rx_overrun       ( uart2_rx_overrun       ),
      .brg_wr           ( uart2_brg_wr           ),
      .brg_d            ( uart2_brg_d            ),
      .autobaud_disable ( uart2_autobaud_disable )
   );
`endif
endmodule

