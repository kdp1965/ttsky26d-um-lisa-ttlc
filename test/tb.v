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
   output wire  [47:0]  ttlc_out,           // the 48 outputs on the 74HC595 chains
   input  wire  [1:0]   spi_map,            // the SPI devices: 0 none, 1 mux-2 pins, 2 the TTLC's (mode 3)
   output wire  [15:0]  spi_count0,         // bytes device 0 / 1 took
   output wire  [15:0]  spi_count1,
   output wire  [15:0]  spi_collide,        // TTLC shift clocks inside an SPI transaction
   output wire  [31:0]  ttlc_differ,        // clocks the 48 outputs differed from the inputs
   input  wire  [47:0]  ttlc_watch,         // a value for the outputs ...
   output wire  [31:0]  ttlc_match,         // ... and the clocks they held it
   input  wire  [15:0]  cap_period,         // Timer 3 (RESPIN 32): a square wave on ui_in[5:4], half-period clocks (0: off)
   output wire  [31:0]  pwm_high0,          // clocks uo_out[1] (PWM0 in mux 2) was high
   output wire  [31:0]  pwm_high1,          // clocks uo_out[2] (PWM1) was high
   output wire  [31:0]  clocks,             // clocks since reset ended
   input  wire          ws_arm,             // WS2812B (RESPIN 33): check from the first pixel decoded after this
   output wire  [15:0]  ws_count1,          // pixels received on uo[1] ...
   output wire  [31:0]  ws_hash1,           // ... their hash (h = h * 33 ^ pixel)
   output wire  [15:0]  ws_frames1,         // ... frames ended by a reset
   output wire  [15:0]  ws_count2,          // the same on uo[2]
   output wire  [31:0]  ws_hash2,
   output wire  [15:0]  ws_frames2,
   output wire  [15:0]  ws_bad,             // high pulses neither a 0 nor a 1, on either
   output wire  [15:0]  ws_other            // rising edges on uo[0], uo[5], uo[6] since ws_arm
);
   wire     [2:0] ttlc_din;
   wire           spi_miso;           // the SPI devices' MISO (ui_in[2])

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

   // ==========================================================================
   // +TRACE=<file>: an instruction trace to compare with lisa_sim's ("trace
   // on").  An I line per instruction fetched: the clock, the code bank and
   // the PC, the word, and the registers as the instructions before it left
   // them (v/d: the data cache's valid and dirty lines); a D line per data
   // access (W/R, bank:address, the byte, whether the cache hit); a P line
   // per peripheral access.  +TRACE_PC=<hex window address> [+TRACE_CB=<bank>]
   // starts the I/D/P lines at the first fetch of that address and
   // +TRACE_COUNT=<n> stops them after n instructions (+TRACE_FINISH ends
   // the simulation there).  C lines (a write of the code bank register) and
   // X lines (an interrupt entry) are written from reset, so the bank
   // switches before the trigger can be compared too.
   // ==========================================================================
   integer        tr_fd = 0;
   reg [1023:0]   tr_file;
   reg [31:0]     tr_pc = 32'hFFFF_FFFF, tr_cb = 32'hFFFF_FFFF, tr_count = 32'hFFFF_FFFF;
   reg            tr_on = 0, tr_armed = 0, tr_isr_r = 0;
   reg [31:0]     tr_cycle = 0;
   // the clock the fetch completes (the core holds a fetch while the store
   // of the instruction before it is still pending: d_we_r)
   wire           tr_fetch = lisa.core_i_fetch & lisa.core_i_ready & !lisa.i_lisa_core.d_we_r;
   wire           tr_hit   = tr_armed && !tr_on && lisa.i_lisa_core.pc == tr_pc[14:0] &&
                             (tr_cb == 32'hFFFF_FFFF || lisa.i_lisa_periph.code_bank == tr_cb[6:0]);
   initial begin
      if ($value$plusargs("TRACE=%s", tr_file))
      begin
         tr_fd = $fopen(tr_file, "w");
         if ($value$plusargs("TRACE_PC=%h", tr_pc)) tr_armed = 1; else tr_on = 1;
         if ($value$plusargs("TRACE_CB=%d", tr_cb)) ;
         if ($value$plusargs("TRACE_COUNT=%d", tr_count)) ;
      end
   end
   always @(posedge clk)
   begin
      tr_cycle <= tr_cycle + 1;
      tr_isr_r <= lisa.i_lisa_core.isr_jump;
      if (tr_fd != 0)
      begin
         if (tr_fetch && tr_hit) tr_on <= 1'b1;
         if (tr_fetch && (tr_on || tr_hit))
         begin
            $fwrite(tr_fd, "I %0d %02X:%04X %04X A=%02X IX=%06X%s SP=%06X RA=%06X%s c=%0d %s%s am=%0d ai=%0d ie=%0d IA=%06X v=%02X d=%02X\n",
                    tr_cycle, lisa.i_lisa_periph.code_bank, lisa.i_lisa_core.pc, lisa.core_inst,
                    lisa.i_lisa_core.acc, lisa.i_lisa_core.ix, lisa.i_lisa_core.ix_cond ? "c" : " ",
                    lisa.i_lisa_core.sp, lisa.i_lisa_core.ra, lisa.i_lisa_core.ra_cond ? "c" : " ",
                    lisa.i_lisa_core.cond, lisa.i_lisa_core.zflag ? "Z" : ".", lisa.i_lisa_core.cflag ? "C" : ".",
                    lisa.i_lisa_core.amode, lisa.i_lisa_core.amode_isr, lisa.i_lisa_core.ie, lisa.i_lisa_core.ia,
                    lisa.i_data_cache.cl_valid, lisa.i_data_cache.cl_dirty);
            if (tr_count != 32'hFFFF_FFFF)
            begin
               tr_count <= tr_count - 1;
               if (tr_count <= 1)
               begin
                  tr_on    <= 1'b0;
                  tr_armed <= 1'b0;
                  $fwrite(tr_fd, "E %0d trace count reached\n", tr_cycle);
                  $fflush(tr_fd);
                  if ($test$plusargs("TRACE_FINISH")) $finish;
               end
            end
         end
         if (tr_on && lisa.d_valid && lisa.d_ready && lisa.d_addr_good && !lisa.d_periph)
            $fwrite(tr_fd, "D %0d %s %06X %02X hit=%0d\n", tr_cycle, lisa.d_we ? "W" : "R",
                    lisa.d_addr, lisa.d_we ? lisa.d_o : lisa.d_i, lisa.i_data_cache.cache_hit);
         if (tr_on && lisa.d_periph && (lisa.d_we || lisa.d_rd))
            $fwrite(tr_fd, "P %0d %s %04X %02X\n", tr_cycle, lisa.d_we ? "W" : "R", lisa.d_addr,
                    lisa.d_we ? lisa.d_o : lisa.d_i);
         // the interrupt enables and acknowledges, from reset (as the C lines)
         if (lisa.d_periph && lisa.d_we && (lisa.d_addr[6:0] == 7'h0E || lisa.d_addr[6:0] == 7'h0F || lisa.d_addr[6:0] == 7'h14))
            $fwrite(tr_fd, "Q %0d %02X:%04X W %02X %02X\n", tr_cycle, lisa.i_lisa_periph.code_bank,
                    lisa.i_lisa_core.pc, lisa.d_addr[7:0], lisa.d_o);
         if (lisa.d_periph && lisa.d_we && lisa.d_addr[6:0] == 7'h15)
            $fwrite(tr_fd, "C %0d %02X:%04X cb<=%02X\n", tr_cycle, lisa.i_lisa_periph.code_bank,
                    lisa.i_lisa_core.pc, lisa.d_o[6:0]);
         if (lisa.cb_we)                 // call ix / jmp ix / ret / rets (REV3.md)
            $fwrite(tr_fd, "C %0d %02X:%04X cb<=%02X (core)\n", tr_cycle, lisa.i_lisa_periph.code_bank,
                    lisa.i_lisa_core.pc, lisa.cb_val);
         if (lisa.i_lisa_core.isr_jump && !tr_isr_r)
            $fwrite(tr_fd, "X %0d %02X:%04X int=%02X\n", tr_cycle, lisa.i_lisa_periph.code_bank,
                    lisa.i_lisa_core.pc, lisa.int_vec);
      end
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
   tt_um_pettit_lisa lisa
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
   assign ui_in[1:0] = porta_in[1:0];
   assign ui_in[2]   = spi_map != 2'h0 ? spi_miso : porta_in[2];
   assign ui_in[7]   = porta_in[7];
   assign ui_in[6]   = ttlc_mode ? ttlc_din[2] : porta_in[6];

   // Timer 3's capture inputs: a square wave of 2 x cap_period clocks
   reg   [15:0]   cap_cnt = 16'h0;
   reg            cap_wave = 1'b0;
   always @(posedge clk)
      if (cap_period == 16'h0)
      begin
         cap_cnt  <= 16'h0;
         cap_wave <= 1'b0;
      end
      else if (cap_cnt == cap_period - 16'h1)
      begin
         cap_cnt  <= 16'h0;
         cap_wave <= ~cap_wave;
      end
      else
         cap_cnt <= cap_cnt + 16'h1;
   assign ui_in[5:4] = ttlc_mode ? ttlc_din[1:0] : cap_period != 16'h0 ? {2{cap_wave}} : porta_in[5:4];

   // the PWM pins' high time
   reg   [31:0]   hi0 = 32'h0, hi1 = 32'h0, clk_n = 32'h0;
   always @(posedge clk)
   begin
      clk_n <= clk_n + 32'h1;
      if (uo_out[1]) hi0 <= hi0 + 32'h1;
      if (uo_out[2]) hi1 <= hi1 + 32'h1;
   end
   // WS2812B receivers on uo[1] and uo[2] (RESPIN 33)
   // before the program turns WS mode on the pins are the TTLC's and the
   // debugger's: malformed pulses and the idle pins count only once a pixel
   // has been decoded (ws_live)
   wire  [15:0]   bad1, bad2;
   wire           ws_live = ws_arm && (ws_count1 != 16'h0 || ws_count2 != 16'h0);
   ws2812_rx i_ws1 ( .clk(clk), .din(uo_out[1]), .live(ws_live), .count(ws_count1), .hash(ws_hash1), .frames(ws_frames1), .bad(bad1) );
   ws2812_rx i_ws2 ( .clk(clk), .din(uo_out[2]), .live(ws_live), .count(ws_count2), .hash(ws_hash2), .frames(ws_frames2), .bad(bad2) );
   assign ws_bad = bad1 + bad2;
   reg   [2:0]    other_last = 3'h0;
   reg   [15:0]   other = 16'h0;
   always @(posedge clk)
   begin
      other_last <= {uo_out[6], uo_out[5], uo_out[0]};
      if (!ws_live)
         other <= 16'h0;
      else if (|({uo_out[6], uo_out[5], uo_out[0]} & ~other_last))
         other <= other + 16'h1;
   end
   assign ws_other = other;

   assign pwm_high0 = hi0;
   assign pwm_high1 = hi1;
   assign clocks    = clk_n;

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
   // The SPI master's devices (RESPIN 29): device 0 (CPHA 0) answers each
   // byte with the complement of the one before, device 1 (CPHA 1) with it
   // plus one; CPOL is the clock's level when the select falls.  On the
   // mux-2 pins SCLK uo[5], MOSI uo[6], CS0 uo[3], CS1 uo[7]; in mode 3
   // SCLK uo[7], MOSI uo[0], CS0 uo[1], CS1 uo[2] - shared with the 595
   // chains' data, so the selects follow the TTLC's data during its scans
   // (no SCLK then).  MISO on ui_in[2].  spi_collide counts the TTLC's shift
   // clocks (uo[6]) inside a transaction: the interlock keeps it 0.
   // ==========================================================================
   wire           spi_sck  = spi_map == 2'h2 ? uo_out[7] : uo_out[5];
   wire           spi_mosi = spi_map == 2'h2 ? uo_out[0] : uo_out[6];
   wire           spi_cs0  = spi_map == 2'h0 ? 1'b1 : spi_map == 2'h2 ? uo_out[1] : uo_out[3];
   wire           spi_cs1  = spi_map == 2'h0 ? 1'b1 : spi_map == 2'h2 ? uo_out[2] : uo_out[7];
   wire           spi_act0, spi_act1;
   reg   [15:0]   collide = 16'h0;
   pullup (spi_miso);

   spi_dev #(.RESET(8'h96), .CPHA(0), .INC(0)) i_spi_dev0
   (
      .cs_n ( spi_cs0 ), .sck ( spi_sck ), .mosi ( spi_mosi ), .miso ( spi_miso ),
      .active ( spi_act0 ), .count ( spi_count0 )
   );
   spi_dev #(.RESET(8'h3c), .CPHA(1), .INC(1)) i_spi_dev1
   (
      .cs_n ( spi_cs1 ), .sck ( spi_sck ), .mosi ( spi_mosi ), .miso ( spi_miso ),
      .active ( spi_act1 ), .count ( spi_count1 )
   );
   always @(uo_out[6])
      if (spi_map == 2'h2 && (spi_act0 || spi_act1))
      begin
         if (collide < 4)
            $display("%t spi collide: uo %02x active %b%b", $time, uo_out, spi_act1, spi_act0);
         collide = collide + 16'h1;
      end
   assign spi_collide = collide;
   // switching the devices to other pins is no clock edge
   always @(spi_map)
   begin
      #1;                                  // after the clock wire has switched
      i_spi_dev0.active = 1'b0;
      i_spi_dev1.active = 1'b0;
   end

   reg   [31:0]   differ = 32'h0;
   always @(posedge clk)
      if (ttlc_out != ttlc_in)
         differ <= differ + 32'h1;
   assign ttlc_differ = differ;

   reg   [31:0]   match = 32'h0;
   always @(posedge clk)
      if (ttlc_out == ttlc_watch)
         match <= match + 32'h1;
   assign ttlc_match = match;

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


// A SPI device for the SPI master's test (RESPIN 29): it answers each byte
// with the complement of the byte before (INC 0) or that byte plus one
// (INC 1), the first byte of a select with RESET.  CPOL is the clock's
// level when the select falls; CPHA 0 samples MOSI on the leading edges and
// shifts MISO on the trailing ones, CPHA 1 the other way round.  active: the
// select is low and the clock has moved in it (a transaction).
module spi_dev
#(
   parameter [7:0] RESET = 8'h00,
   parameter       CPHA  = 0,
   parameter       INC   = 0
)
(
   input  wire          cs_n,
   input  wire          sck,
   input  wire          mosi,
   output wire          miso,
   output reg           active,
   output reg  [15:0]   count
);
   reg         cpol;
   reg  [7:0]  sr_in;
   reg  [7:0]  sr_out;
   reg  [7:0]  next;
   reg  [3:0]  n;
   reg         first;

   initial begin
      cpol = 1'b0; count = 16'h0; active = 1'b0; next = RESET;
      sr_out = RESET; n = 4'h0; first = 1'b1; sr_in = 8'h0;
   end

   assign miso = cs_n ? 1'bz : sr_out[7];

   always @(negedge cs_n)
   begin
      cpol   = sck;
      n      = 4'h0;
      first  = 1'b1;
      next   = RESET;
      sr_out = RESET;
   end
   always @(posedge cs_n)
      active = 1'b0;

   task take;
   begin
      sr_in = {sr_in[6:0], mosi};
      n = n + 4'h1;
      if (n == 4'h8)
      begin
         n     = 4'h0;
         count = count + 16'h1;
         next  = INC ? sr_in + 8'h1 : ~sr_in;
      end
   end
   endtask

   // the clock's edges: leading away from CPOL, trailing back to it
   always @(sck)
      if (!cs_n)
      begin
         active = 1'b1;
         if (sck != cpol)
         begin
            if (CPHA == 0)
               take;
            else if (first)
               first = 1'b0;
            else
               sr_out = (n == 4'h0) ? next : {sr_out[6:0], 1'b0};
         end
         else
         begin
            if (CPHA == 0)
               sr_out = (n == 4'h0) ? next : {sr_out[6:0], 1'b0};
            else
               take;
         end
      end
endmodule

// A WS2812B's input as the testbench sees it (RESPIN 33): a high pulse of
// 12-28 clocks is a 0, 32-48 a 1 (the driver's 20 / 40 at 50 MHz), any
// other a bad one; 24 bits MSB first are a pixel (G, R, B); the line low
// for 10000 clocks ends a frame (the part latches) and drops a partial pixel.
module ws2812_rx
(
   input  wire          clk,
   input  wire          din,
   input  wire          live,              // count malformed pulses
   output reg  [15:0]   count = 16'h0,
   output reg  [31:0]   hash = 32'h0,
   output reg  [15:0]   frames = 16'h0,
   output reg  [15:0]   bad = 16'h0
);
   reg            last = 1'b0;
   reg   [15:0]   width = 16'h0;
   reg   [15:0]   low = 16'h0;
   reg   [23:0]   pix = 24'h0;
   reg   [4:0]    nbits = 5'h0;
   reg            inframe = 1'b0;
   always @(posedge clk)
   begin
      last <= din;
      if (din)
      begin
         width <= last ? width + 16'h1 : 16'h1;
         low   <= 16'h0;
      end
      else
      begin
         if (low != 16'hFFFF) low <= low + 16'h1;
         if (low == 16'd10000)
         begin
            if (inframe) frames <= frames + 16'h1;
            inframe <= 1'b0;
            nbits   <= 5'h0;
         end
      end
      if (last && !din)
      begin
         if ((width >= 12 && width <= 28) || (width >= 32 && width <= 48))
         begin
            if (nbits == 5'd23)
            begin
               count   <= count + 16'h1;
               hash    <= ({hash[26:0], 5'b0} + hash) ^ {8'h0, pix[22:0], width >= 32};
               nbits   <= 5'h0;
               inframe <= 1'b1;
            end
            else
               nbits <= nbits + 5'h1;
            pix <= {pix[22:0], width >= 32};
         end
         else if (live)
            bad <= bad + 16'h1;
      end
   end
endmodule
