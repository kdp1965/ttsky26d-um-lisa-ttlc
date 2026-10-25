`default_nettype none
`timescale 1ns / 1ps

/* tb_core: the LISA core with its data path as on the chip (the registered
   data bus, the 8-line data cache, the RAM32, the QSPI sequencer and a QSPI
   RAM model on CE1, the peripherals), but the instructions straight from an
   array and the debug port driven by test_core.py - no SPI fetch, no UART
   framing, so programs run at a few clocks per instruction.
   +FIRMWARE=<hex>  the image (@byteaddr hex bytes, as ihx2hex.py writes)
   +ILAT=1          one clock of fetch latency (the instruction cache after a
                    miss) instead of none (a hit)
   +DUMP            tb_core.vcd  */
module tb_core;

   reg            clk = 1'b0;
   always #10 clk = ~clk;                    // 50 MHz
   reg            rst_n = 1'b0;
   reg            core_reset = 1'b0;        // the debugger's 't'

   // the debug port (lisa_dbg inside the core)
   reg  [7:0]     dbg_a = 8'h0;
   reg  [15:0]    dbg_di = 16'h0;
   reg            dbg_we = 1'b0;
   reg            dbg_rd = 1'b0;
   wire [15:0]    dbg_do;
   wire           dbg_ready;
   wire           dbg_halted;

   // the cache configuration (debug_regs on the chip)
   reg            cache_disabled = 1'b1;
   reg  [1:0]     cache_map_sel = 2'h3;
   reg            data_cache_flush = 1'b0;
   reg            data_cache_invalidate = 1'b0;
   wire           data_cache_flush_ack;
   wire           data_cache_invalidate_ack;

   // the console: what the program writes to its UART, what the test feeds it
   wire [7:0]     uart_tx_d;
   wire           uart_tx_wr;
   wire           uart_rx_rd;
   reg  [7:0]     uart_rx_d = 8'h0;
   reg            uart_rx_avail = 1'b0;

   // ports and interrupts
   reg  [7:0]     porta_in = 8'h0;
   reg  [3:0]     portc_in = 4'h0;
   reg  [7:0]     portd_in = 8'h0;
   reg            ttlc_int = 1'b0;
   wire [7:0]     portb;
   wire [3:0]     portc;
   wire [3:0]     portc_dir;
   wire [7:0]     porte;
   wire [8:0]     int_vec;
   wire [7:0]     int_en_vec;

   initial begin
      if ($test$plusargs("DUMP"))
      begin
         $dumpfile("tb_core.vcd");
         $dumpvars(0, tb_core);
      end
   end

   // ==========================================================================
   // The program: a byte image into a word array
   // ==========================================================================
   reg  [7:0]     fmem[0:4194303];         // 128 code banks of 16K words (REV3.md)
   reg  [15:0]    imem[0:2097151];
   reg  [8*256-1:0] fname;
   integer        k;
   integer        ilat;
   initial begin
      for (k = 0; k < 4194304; k = k + 1)
         fmem[k] = 8'hFF;
      if (!$value$plusargs("FIRMWARE=%s", fname))
         fname = "../firmware.hex";
      $readmemh(fname, fmem);
      for (k = 0; k < 2097152; k = k + 1)
         imem[k] = {fmem[2*k+1], fmem[2*k]};
      if (!$value$plusargs("ILAT=%d", ilat))
         ilat = 0;
   end

   wire [14:0]    i_addr;
   wire           i_fetch;
   wire           i_kfetch;
   wire [6:0]     i_kbank;
   wire [6:0]     code_bank;
   wire           cb_we;
   wire [6:0]     cb_val;
   wire [15:0]    inst_i;
   wire           inst_ready;
   reg  [15:0]    inst_r;
   reg            ready_r;
   // the physical word as tt_um_pettit_lisa.v forms it: the upper 16K words from
   // the code bank (or the constant's bank in IX), the lower common
   wire [20:0]    i_paddr = i_kfetch ? {i_addr[14] ? i_kbank : 7'h0, i_addr[13:0]} :
                                       {i_addr[14] ? code_bank : 7'h0, i_addr[13:0]};
   always @(posedge clk)
   begin
      inst_r  <= imem[i_paddr];
      ready_r <= i_fetch;
   end
   // a hit answers in the fetch clock; after a miss the line arrives later
   assign inst_i     = ilat == 0 ? imem[i_paddr] : inst_r;
   assign inst_ready = ilat == 0 ? i_fetch : (ready_r & i_fetch);

   // ==========================================================================
   // The core
   // ==========================================================================
   wire [7:0]     d_i;
   wire [7:0]     d_i_cache;
   wire [7:0]     d_i_periph;
   wire [7:0]     d_o_c;
   wire [22:0]    d_addr_c;
   wire           d_periph_c;
   wire           d_we_c;
   wire           d_rd_c;
   wire           d_valid_c;
   wire           d_ready;
   wire           d_addr_good;

   lisa_core i_lisa_core
   (
      .clk          ( clk           ),
      .rst_n        ( rst_n         ),
      .rst_async_n  ( rst_n         ),
      .reset        ( core_reset    ),
      .inst_i       ( inst_i        ),
      .inst_ready   ( inst_ready    ),
      .i_fetch      ( i_fetch       ),
      .i_addr       ( i_addr        ),
      .i_kfetch     ( i_kfetch      ),
      .i_kbank      ( i_kbank       ),
      .code_bank    ( code_bank     ),
      .cb_we        ( cb_we         ),
      .cb_val       ( cb_val        ),
      .inst_o       (               ),
      .inst_we      (               ),
      .d_i          ( d_i           ),
      .d_o          ( d_o_c         ),
      .d_addr       ( d_addr_c      ),
      .d_periph     ( d_periph_c    ),
      .d_we         ( d_we_c        ),
      .d_rd         ( d_rd_c        ),
      .d_valid      ( d_valid_c     ),
      .d_ready      ( d_ready & d_addr_good ),
      .int_i        ( int_vec       ),
      .int_en       ( {1'b1, int_en_vec} ),
      .dbg_a        ( dbg_a         ),
      .dbg_di       ( dbg_di        ),
      .dbg_do       ( dbg_do        ),
      .dbg_we       ( dbg_we        ),
      .dbg_rd       ( dbg_rd        ),
      .dbg_ready    ( dbg_ready     ),
      .dbg_halted   ( dbg_halted    )
   );

   // the data bus registered as in tt_um_pettit_lisa.v
   reg  [7:0]     d_o;
   reg  [22:0]    d_addr;
   reg            d_valid;
   reg            d_we;
   reg            d_rd;
   reg            d_periph;
   assign d_addr_good = d_addr_c == d_addr;
   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         d_o      <= 8'h0;
         d_addr   <= 23'h0;
         d_valid  <= 1'b0;
         d_we     <= 1'b0;
         d_rd     <= 1'b0;
         d_periph <= 1'b0;
      end
      else
      begin
         d_o      <= d_o_c;
         d_addr   <= d_addr_c;
         d_valid  <= d_valid_c;
         d_we     <= d_we_c;
         d_rd     <= d_rd_c;
         d_periph <= d_periph_c;
      end
   end
   assign d_i = d_periph ? d_i_periph : d_i_cache;

   // ==========================================================================
   // The data cache, the RAM32 and the QSPI RAM behind the cache
   // ==========================================================================
   wire [3:0]     ram_we;
   wire           ram_en;
   wire [4:0]     ram_a;
   wire [31:0]    ram_di;
   wire [31:0]    ram_do;
   wire [22:0]    cache_addr;
   wire [15:0]    q_rdata;
   wire [15:0]    q_wdata;
   wire [1:0]     q_wstrb;
   wire           q_ready;
   wire           q_ready_ack;
   wire           q_xfer_done;
   wire           q_valid;
   wire [3:0]     q_xfer_len;

   data_cache i_data_cache
   (
      .clk                       ( clk                       ),
      .rst_n                     ( rst_n                     ),
      .disabled                  ( cache_disabled            ),
      .d_addr                    ( d_addr                    ),
      .d_i                       ( d_o                       ),
      .d_o                       ( d_i_cache                 ),
      .d_valid                   ( d_valid                   ),
      .d_we                      ( d_we                      ),
      .d_periph                  ( d_periph                  ),
      .d_ready                   ( d_ready                   ),
      .ram_we                    ( ram_we                    ),
      .ram_en                    ( ram_en                    ),
      .ram_a                     ( ram_a                     ),
      .ram_di                    ( ram_do                    ),
      .ram_do                    ( ram_di                    ),
      .cache_map_sel             ( cache_map_sel             ),
      .data_cache_flush          ( data_cache_flush          ),
      .data_cache_flush_ack      ( data_cache_flush_ack      ),
      .data_cache_invalidate     ( data_cache_invalidate     ),
      .data_cache_invalidate_ack ( data_cache_invalidate_ack ),
      .qspi_addr                 ( cache_addr                ),
      .qspi_rdata                ( q_rdata                   ),
      .qspi_wdata                ( q_wdata                   ),
      .qspi_wstrb                ( q_wstrb                   ),
      .qspi_ready                ( q_ready                   ),
      .qspi_ready_ack            ( q_ready_ack               ),
      .qspi_xfer_done            ( q_xfer_done               ),
      .qspi_valid                ( q_valid                   ),
      .qspi_xfer_len             ( q_xfer_len                )
   );

   RAM32 ram1
   (
      .CLK  ( clk    ),
      .WE0  ( ram_we ),
      .EN0  ( ram_en ),
      .A0   ( ram_a  ),
      .Di0  ( ram_di ),
      .Do0  ( ram_do )
   );

   wire           sclk;
   wire [1:0]     ce;
   wire           sio0_o, sio1_o, sio2_o, sio3_o;
   wire [3:0]     sio_oe;
   wire           dq0, dq1, dq2, dq3;

   lisa_qqspi i_lisa_qqspi
   (
      .addr              ( {1'b0, cache_addr} ),
      .rdata             ( q_rdata       ),
      .wdata             ( q_wdata       ),
      .wstrb             ( q_wstrb       ),
      .ready             ( q_ready       ),
      .ready_ack         ( q_ready_ack   ),
      .xfer_done         ( q_xfer_done   ),
      .valid             ( q_valid       ),
      .xfer_len          ( q_xfer_len    ),
      .clk               ( clk           ),
      .rst_n             ( rst_n         ),
      .addr_16b          ( 2'b00         ),
      .is_flash          ( 2'b00         ),
      .quad_mode         ( 2'b11         ),
      .sclk              ( sclk          ),
      .sio0_si_mosi_i    ( dq0           ),
      .sio1_so_miso_i    ( dq1           ),
      .sio2_i            ( dq2           ),
      .sio3_i            ( dq3           ),
      .sio0_si_mosi_o    ( sio0_o        ),
      .sio1_so_miso_o    ( sio1_o        ),
      .sio2_o            ( sio2_o        ),
      .sio3_o            ( sio3_o        ),
      .sio_oe            ( sio_oe        ),
      .ce_ctrl           ( 2'b10         ),       // the data RAM on CE1
      .spi_mode          ( 2'b00         ),
      .spi_rd_late        ( 2'b00           ),
      .ce                ( ce            ),
      .dummy_read_cycles ( 8'h66         ),
      .spi_clk_div       ( 4'h0          ),
      .spi_ce_delay      ( 7'h1          ),
      .custom_spi_cmd    ( 1'b0          ),
      .cmd_quad_write    ( 8'h38         )
   );

   assign dq0 = sio_oe[0] ? sio0_o : 1'bz;
   assign dq1 = sio_oe[1] ? sio1_o : 1'bz;
   assign dq2 = sio_oe[2] ? sio2_o : 1'bz;
   assign dq3 = sio_oe[3] ? sio3_o : 1'bz;
   pullup (dq0);
   pullup (dq1);
   pullup (dq2);
   pullup (dq3);

   psram psram_I
   (
      .ce_n ( ce[1]                ),
      .sck  ( sclk                 ),
      .dio  ( {dq3, dq2, dq1, dq0} )
   );

   // ==========================================================================
   // The peripherals: the UART's bytes are taken straight off the bus
   // ==========================================================================
   lisa_periph i_lisa_periph
   (
      .clk                ( clk             ),
      .rst_n              ( rst_n           ),
      .rst_por_n          ( rst_n           ),
      .rst_async_n        ( rst_n           ),
      .d_i                ( d_o             ),
      .d_o                ( d_i_periph      ),
      .d_addr             ( d_addr[6:0]     ),
      .d_periph           ( d_periph        ),
      .d_we               ( d_we            ),
      .d_rd               ( d_rd            ),
      .code_bank          ( code_bank       ),
      .cb_we              ( cb_we           ),
      .cb_val             ( cb_val          ),
      .porta_in           ( porta_in        ),
      .portb              ( portb           ),
      .portc              ( portc           ),
      .portc_in           ( portc_in        ),
      .portc_dir          ( portc_dir       ),
      .portd_in           ( portd_in        ),
      .porte              ( porte           ),
      .int_o              ( int_vec         ),
      .int_en             ( int_en_vec      ),
      .ttlc_int           ( ttlc_int        ),
      .uart_tx_d          ( uart_tx_d       ),
      .uart_tx_wr         ( uart_tx_wr      ),
      .uart_rx_rd         ( uart_rx_rd      ),
      .uart_rx_d          ( uart_rx_d       ),
      .uart_rx_data_avail ( uart_rx_avail   ),
      .uart_tx_buf_empty  ( 1'b1            ),
      .uart2_rx           ( 1'b1            ),
      .uart2_tx           (                 ),
      .scl_pad_i          ( 1'b1            ),
      .scl_pad_o          (                 ),
      .scl_padoen_o       (                 ),
      .sda_pad_i          ( 1'b1            ),
      .sda_pad_o          (                 ),
      .sda_padoen_o       (                 ),
      .spi_miso_in        ( 4'hf            ),
      .spi_sclk           (                 ),
      .spi_sclk_m3        (                 ),
      .spi_mosi           (                 ),
      .spi_cs_n           (                 ),
      .ttlc_scan_req      ( 1'b0            ),
      .ttlc_scan_busy     ( 1'b0            ),
      .spi_owned          (                 ),
      .ttlc_idx           (                 ),
      .ttlc_wdata         (                 ),
      .ttlc_we            (                 ),
      .ttlc_rdata         ( 8'h0            ),
      .ttlc_lisa_start    (                 ),
      .t3_cap_in          ( 2'b00           ),
      .t3_pwm             (                 ),
      .t3_pwm_oe          (                 ),
      .ws_pixels          ( 48'h0           ),
      .ws_en              (                 ),
      .ws_pins            (                 ),
      .ws_grp             ( 48'h0           ),
      .ws_grp_valid       ( 1'b0            ),
      .ws_fetch_idle      ( 1'b1            ),
      .ws_flush_ack       ( 1'b1            ),
      .ws_flush_req       (                 ),
      .ws_dma_fetch       (                 ),
      .ws_restart         (                 ),
      .ws_adv             (                 ),
      .ws_last_grp        (                 ),
      .ws_base            (                 ),
      .wdt_reset          (                 )
   );

   // the console input: a byte stays until the program reads it
   always @(posedge clk)
      if (uart_rx_rd && uart_rx_avail)
         uart_rx_avail <= 1'b0;

   // +TRACEPC=<hex>: whenever that instruction executes with C set, print
   // where the last interrupt landed (a non-intrusive look at a timing race)
   integer        trace_pc;
   integer        trace_win;
   reg [14:0]     irq_pc;
   reg [15:0]     irq_inst;
   reg [1:0]      irq_cond;
   reg            irq_c, irq_csave, irq_inv;
   reg [2:0]      irq_amode;
   initial
   begin
      if (!$value$plusargs("TRACEPC=%h", trace_pc))
         trace_pc = -1;
      if (!$value$plusargs("TRACEWIN=%h", trace_win))
         trace_win = -1;
   end
   always @(posedge clk)
   begin
      if (i_lisa_core.irq_take)
      begin
         irq_pc    <= i_lisa_core.pc;
         irq_inst  <= i_lisa_core.inst;
         irq_cond  <= i_lisa_core.cond;
         irq_c     <= i_lisa_core.cflag;
         irq_csave <= i_lisa_core.cflag_save;
         irq_inv   <= i_lisa_core.signed_inversion;
         irq_amode <= i_lisa_core.amode;
      end
      if (i_lisa_core.exec_state && i_lisa_core.d_ok && i_lisa_core.pc == trace_pc[14:0] && i_lisa_core.cflag)
         $display("TRACE pc %h: C=1, A %h sp %h; the interrupt landed on pc %h inst %h cond %b C %b Csave %b inv %b amode %h",
                  i_lisa_core.pc, i_lisa_core.acc, i_lisa_core.sp, irq_pc, irq_inst, irq_cond, irq_c, irq_csave, irq_inv, irq_amode);
      // +TRACEWIN=<hex>: every data access of the instructions from that PC on (16 of them)
      if (trace_win >= 0 && i_lisa_core.pc >= trace_win[14:0] && i_lisa_core.pc < trace_win[14:0] + 16 && d_we)
         $display("  W pc %h sp %h  [%h] <= %h", i_lisa_core.pc, i_lisa_core.sp, d_addr, d_o);
      if (trace_win >= 0 && i_lisa_core.pc >= trace_win[14:0] && i_lisa_core.pc < trace_win[14:0] + 16 &&
          i_lisa_core.exec_state && i_lisa_core.d_ok && i_lisa_core.d_valid)
         $display("  R pc %h sp %h  [%h] -> %h  (inst %h)", i_lisa_core.pc, i_lisa_core.sp, d_addr, d_i, i_lisa_core.inst);
   end

endmodule
