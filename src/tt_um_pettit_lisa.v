/*
==============================================================================
tt_um_pettit_lisa.v:  Tiny Tapeout User Module for the LISA 8-bit processor.

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

// ==============================================================================
// I/O Usage:
//
//
//                          +------------------------+
//                          |   tt_um_pettit_lisa    |
//          On              |                        |
//         Reset            |ui_in             uo_out|
//           |          pa0 | 0                    0 | pb0
//           |          pa1 | 1                    1 | pb1
//     baud  |          pa2 | 2                    2 | pb2
//      div -+     rx / pa3 | 3                    3 | pb3
//           |          pa4 | 4                    4 | pb4 / tx
//           |          pa5 | 5                    5 | pb5
//           |          pa6 | 6                    6 | pb6
//           baud_set / pa7 | 7                    7 | pb7 / baud_ref
//                          |                        |
//                          |                   uio  |
//                          |                      0 | cs    / ce_latch
//                          |                      1 | mosi  / dq1 / ce0
//                          |                      2 | miso  / dq2 / ce1
//                          |                      3 | sclk
//                          |                      4 | scl / rx  / portc_io[0]
//                          |                      5 | sda / tx  / portc_io[1]
//                          |                      6 | scl / dq3 / portc_io[2] / rx
//                          |                      7 | sda / dp4 / portc_io[3]
//                          |                        |
//                          +------------------------+
//
//
//   ui: Sampled at reset
//      7: HIGH to sample ui[6:0] as BAUD divider at reset and disable AutoBaud
//    6-0: When [7] is HIGH at reset, sets the UART BAUD divider.
//
// ==============================================================================

`define WANT_UART2

module tt_um_pettit_lisa
(
`ifdef USE_POWER_PINS
    input                  VPWR,
    input                  VGND,
`endif
   input   wire [7:0]      ui_in,            // Connected to the input switches
   output  wire [7:0]      uo_out,           // Connected to the 7 segment display
   input   wire [7:0]      uio_in,
   output  wire [7:0]      uio_out,
   output  wire [7:0]      uio_oe,           // BIDIR Enable (0=input, 1=output)
   
   // Control inputs
   input   wire            ena,              // Will go high when the design is enabled
   input   wire            clk,              // System clock 
   /* verilator lint_off SYNCASYNCNET */
   input   wire            rst_n             // Active low reset
   /* verilator lint_on SYNCASYNCNET */
);
   // ==========================================================================
   // Debug bus signals
   // ==========================================================================
   wire                 debug_rx;
   wire                 debug_tx;
   wire                 baud_ref;

   reg  [2:0]           rst_n_r;
   /* verilator lint_off SYNCASYNCNET */
   reg  [2:0]           rst_async_n_r;
   /* verilator lint_on SYNCASYNCNET */

   // ==========================================================================
   // I/O mux control signals
   // ==========================================================================
   wire [15:0]          output_mux_bits;     // Output select bits per output
   wire [7:0]           io_mux_bits;         // I/O select bits per BIDIR

   // ==========================================================================
   // Processor Instruction RAM bus
   // ==========================================================================
   wire   [14:0]        core_i_addr;
   wire   [15:0]        core_inst;
   wire   [15:0]        core_inst_o;
   wire                 core_inst_we;
   wire                 core_i_ready;
   wire                 core_i_fetch;

   // ==========================================================================
   // Processor DATA RAM bus
   // ==========================================================================
   wire   [22:0]        d_addr;              // the flat 8 MB data space (REV3.md)
   wire   [7:0]         d_i;
   wire   [7:0]         d_i_cache;
   wire   [7:0]         d_i_periph;
   wire   [7:0]         d_o;
   wire                 d_we;
   wire                 d_rd;
   wire                 d_periph;
   wire                 d_valid;
   wire                 d_ready;
   wire   [31:0]        ram_do;
   wire   [31:0]        ram_di;
   wire   [3:0]         ram_we;
   wire   [4:0]         ram_a;
   wire                 ram_en;
   wire                 cache_disabled;
   wire   [1:0]         cache_map_sel;
   wire                 data_cache_flush;
   wire                 data_cache_flush_ack;
   wire                 data_cache_invalidate;
   wire                 data_cache_invalidate_ack;
   wire                 inst_cache_invalidate;
   wire                 inst_cache_invalidate_ack;

   // ==========================================================================
   // Processor Interrupts
   // ==========================================================================
   wire   [8:0]         int_vec;             // bit 8: Timer 3 (RESPIN 32)
   wire   [7:0]         int_en_vec;
   wire   [1:0]         t3_pwm;
   wire                 ws_en;               // RESPIN 33: the WS2812B driver
   wire   [4:0]         ws_pins;
   wire   [47:0]        ws_grp;              // RESPIN 35: its DMA through the TTLC's fetch
   wire                 ws_grp_valid;
   wire                 ws_fetch_idle;
   wire                 ws_flush_req;
   wire                 ws_dma_fetch;
   wire                 ws_restart;
   wire                 ws_adv;
   wire   [11:0]        ws_last_grp;
   wire   [15:0]        ws_base;
   wire                 dbg_cache_flush;     // the debugger's flush (the driver's ORed in)
   wire   [1:0]         t3_pwm_oe;

   // ==========================================================================
   // Debug signals
   // ==========================================================================
   wire   [7:0]         dbg_a;
   wire   [15:0]        dbg_di;
   wire   [15:0]        dbg_do;
   wire   [15:0]        dbg_do_lisa;
   wire   [15:0]        dbg_do_regs;
   wire                 dbg_we;
   wire                 dbg_rd;
   wire                 dbg_reset;
   wire                 dbg_ready;
   wire                 dbg_ready_lisa;
   wire                 dbg_ready_regs;
   wire                 dbg_halted;

   // ==========================================================================
   // Lisa Peripheral signals
   // ==========================================================================
   wire    [7:0]        porta_in;   
   wire    [7:0]        portb;
   wire    [3:0]        portc;
   wire    [3:0]        portc_in;
   wire    [3:0]        portc_dir;

   // ==========================================================================
   // Lisa UART signals
   // ==========================================================================
   wire    [7:0]        lisa_tx_d;
   wire    [7:0]        lisa_rx_d;
   wire                 lisa_tx_wr;
   wire                 lisa_rx_rd;
   wire                 lisa_rx_data_avail;
   wire                 lisa_tx_buf_empty;
   wire                 lisa_rx_overrun;
   reg                  rx1_r1, rx1_r2;
   reg                  rx2_r1, rx2_r2;
   reg                  rx3_r1, rx3_r2;

`ifdef WANT_UART2
   wire                 uart2_rx;
   wire                 uart2_tx;
`endif

   // ==========================================================================
   // Lisa I2C
   // ==========================================================================
   wire                 scl_pad_i;
   wire                 scl_pad_o;
   wire                 scl_padoen_o;
   wire                 sda_pad_i;
   wire                 sda_pad_o;
   wire                 sda_padoen_o;

   // ==========================================================================
   // Baud rate control signals
   // ==========================================================================
   wire    [6:0]        baud_div;
   wire                 baud_set;
   wire                 brg_wr;
   wire    [13:0]       brg_div;
   wire    [1:0]        rx_sel;

   // ==========================================================================
   // QSPI Arbiter debug signals
   // ==========================================================================
   wire [23:0]          debug_addr;          // 8Mx32
   wire [15:0]          debug_rdata;         // Read data
   wire [15:0]          debug_wdata;         // Data to write
   wire [1:0]           debug_wstrb;         // Which bytes in the 32-bits to write
   wire                 debug_ready;         // Next 32-bit value is ready
   wire                 debug_ready_ack;     // Next 32-bit value is ready
   wire                 debug_valid;         // Indicates a valid request 
   wire [3:0]           debug_xfer_len;      // Number of 32-bit words to transfer
   wire [1:0]           debug_ce_ctrl;
   wire [7:0]           cmd_quad_write;
   wire                 custom_spi_cmd;
   wire [7:0]           dbg_cmd_quad_write;
   wire                 dbg_custom_spi_cmd;
   wire [3:0]           plus_guard_time;
                        
   // ==========================================================================
   // QSPI Arbiter Lisa instruction bus signals
   // ==========================================================================
   wire [23:0]          lisa1_addr;          // 8Mx32
   wire [15:0]          lisa1_rdata;         // Read data
   wire [15:0]          lisa1_wdata;         // Data to write
   wire [1:0]           lisa1_wstrb;         // Which bytes in the 32-bits to write
   wire                 lisa1_ready;         // Next 32-bit value is ready
   wire                 lisa1_ready_ack;     // Next 32-bit value is ready
   wire                 lisa1_xfer_done;     // Total xfer_len transfer is done
   wire                 lisa1_valid;         // Indicates a valid request 
   wire [3:0]           lisa1_xfer_len;      // Number of 32-bit words to transfer
   wire [1:0]           lisa1_ce_ctrl;
   wire                 lisa1_stream;        // The instruction burst stays open
   wire                 lisa1_yield;         // ... another client wants the QSPI
   wire [20:0]          lisa1_word_addr;     // The word the burst starts at: {bank[6:0], PC[13:0]}
   wire [15:0]          lisa1_base_addr;
                        
   // ==========================================================================
   // QSPI Arbiter Lisa data bus signals
   // ==========================================================================
   wire [23:0]          lisa2_addr;          // 8Mx32
   wire [22:0]          cache_addr;          // the line's byte address
   wire [15:0]          lisa2_rdata;         // Read data
   wire [15:0]          lisa2_wdata;         // Data to write
   wire [1:0]           lisa2_wstrb;         // Which bytes in the 32-bits to write
   wire                 lisa2_ready;         // Next 32-bit value is ready
   wire                 lisa2_ready_ack;     // Next 32-bit value is ready
   wire                 lisa2_xfer_done;     // Total xfer_len transfer is done
   wire                 lisa2_valid;         // Indicates a valid request 
   wire [3:0]           lisa2_xfer_len;      // Number of 32-bit words to transfer
   wire [1:0]           lisa2_ce_ctrl;
   wire [15:0]          lisa2_base_addr;
                        
   // ==========================================================================
   // QSPI Arbiter MC14500 instruction bus signals
   // ==========================================================================
   wire [23:0]          ttlc_addr;           // 8Mx32
   wire [15:0]          ttlc_rdata;          // Read data
   wire [15:0]          ttlc_wdata;          // Data to write
   wire [1:0]           ttlc_wstrb;          // Which bytes in the 32-bits to write
   wire                 ttlc_ready;          // Next 32-bit value is ready
   wire                 ttlc_ready_ack;      // Next 32-bit value is ready
   wire                 ttlc_xfer_done;      // Total xfer_len transfer is done
   wire                 ttlc_valid;          // Indicates a valid request 
   wire [3:0]           ttlc_xfer_len;       // Number of 32-bit words to transfer
   wire [1:0]           ttlc_ce_ctrl;
   (* keep = "true" *)
   wire [15:0]          ttlc_base_addr;
                        
   // ==========================================================================
   // QSPI module control signals
   // ==========================================================================
   wire [23:0]          addr;                // 8Mx32
   wire [15:0]          rdata;               // Read data
   wire [15:0]          wdata;               // Data to write
   wire [1:0]           wstrb;               // Which bytes in the 32-bits to write
   wire                 ready;               // Next 32-bit value is ready
   wire                 ready_ack;           // Next 32-bit write value is ready
   wire                 xfer_done;           // Total xfer_len transfer is done
   wire                 valid;               // Indicates a valid request 
   wire [3:0]           xfer_len;            // Number of 32-bit words to transfer
   wire                 stream;              // The active client's read burst goes on

   // ==========================================================================
   // Chip select controls
   // ==========================================================================
   wire [1:0]           ce_ctrl;
   wire [1:0]           addr_16b;
   wire [1:0]           is_flash;
   wire [1:0]           quad_mode;
   wire [7:0]           dummy_read_cycles;
   wire [3:0]           spi_clk_div;
   wire [6:0]           spi_ce_delay;
   wire [1:0]           spi_mode;
   wire [1:0]           spi_rd_late;         // RESPIN 34: late read capture per select

   // ==========================================================================
   // The QSPI I/O signals
   // ==========================================================================
   wire                 sclk;
   wire                 sio0_si_mosi_i;
   wire                 sio1_so_miso_i;
   wire                 sio2_i;
   wire                 sio3_i;
   wire                 sio0_si_mosi_o;
   wire                 sio1_so_miso_o;
   wire                 sio2_o;
   wire                 sio3_o;
   wire [3:0]           sio_oe;
   wire [1:0]           ce;
                             
   // ==========================================================================
   // MC14500 interface signals
   // ==========================================================================
   (* keep = "true" *)
   wire                 mc14500_run;
   (* keep = "true" *)
   wire [13:0]          mc14500_pc;          // {group, slot} (ttlc_fetch.v)
   (* keep = "true" *)
   (* keep = "true" *)
   wire                 ttlc_halt;
   wire                 ttlc_exec;
   wire                 ttlc_reset;
   wire                 ttlc_shiftclk;
   wire                 DATA;
   wire                 WRITE;
   wire                 DATA_OUT;
   wire                 RR;
   wire                 JMP;
   wire                 RTN;
   wire                 FLAG_O;
   wire                 FLAG_F;

   // ==========================================================================
   // MC14500 I/O signals
   // ==========================================================================
   wire [11:0]          address;       // 12-bit address bus
   wire                 mem_write;     // Memory write enable
   wire                 data_in;       // Data input for writes
   wire                 data_out;      // Data output pin, continuously assigned
   wire                 rr_value;      // RR output from MC14500B
   wire [47:0]          input_pins;    // External input pins
   reg  [47:0]          output_pins;   // Driven from internal registers, renumbered

   // The shift register I/O interface
   wire                 ttlc_io_latch;
   wire                 ttlc_io_shiftclk;
   wire                 ttlc_io_start;
   wire [2:0]           ttlc_out_data;
   wire [2:0]           ttlc_in_data;
   wire                 psram_mod;           // 0x1c bit 10: the TT QSPI Pmod's uio[7:4] (lisa_io_mux.v)
   wire [1:0]           clk_div;             // Clock division factor control (00: /2, 01: /4, 10: /8, 11: /16)
   wire                 io_busy;
   reg                  io_busy_r;
   wire [7:0]           ttlc_to_lisa;
   wire [7:0]           lisa_to_ttlc;
   wire                 ttlc_int;

   // The SPI master (RESPIN 29, lisa_spi.v) and its interlock with the scan
   wire                 spi_sclk;
   wire                 spi_sclk_m3;         // ... on the TTLC's pins
   wire                 spi_mosi;
   wire [1:0]           spi_cs_n;
   wire                 spi_owned;           // the TTLC's mode-3 pins are the SPI's
   wire                 ttlc_scan_req;       // FLAG_O, or a scan waiting for them
   wire [4:0]           ttlcio_idx;          // RESPIN 30: the core's byte port
   wire [7:0]           ttlcio_wdata;
   wire                 ttlcio_we;
   wire [7:0]           ttlcio_rdata;
   wire                 ttlc_lisa_start;     // a scan the core started (TCTRL START)
   reg                  ttlc_scan_pend;

   // ==========================================================================
   // Processor Instruction RAM bus
   // ==========================================================================
   wire   [13:0]        ttlc_fetch_word;     // the group being fetched, in words
   wire   [11:0]        ttlc_inst;           // the slot at the PC: {address[7:0], opcode[3:0]}
   wire                 ttlc_i_ready;

   // ==========================================================================
   // CACHE control signals
   // ==========================================================================
   wire                 ttlc_cache_invalidate;
   wire                 ttlc_cache_invalidate_ack;

   // ==========================================================================
   // Synchronous release async reset
   // ==========================================================================
   always @(posedge clk or negedge rst_n)
   begin
      if (~rst_n)
      begin
         rst_n_r <= 3'h0;
         rst_async_n_r <= 3'h0;
      end
      else
      begin
         rst_n_r <= {rst_n_r[1:0], 1'b1};
         rst_async_n_r <= {rst_async_n_r[1:0], 1'b1};
      end
   end
   
   wire [7:0]  d_o_c;
   wire [22:0] d_addr_c;
   wire        d_valid_c;
   wire        d_we_c;
   wire        d_rd_c;
   wire        d_periph_c;
   wire        d_addr_good;
   wire [6:0]  code_bank;           // CB: 7 bits, 128 code banks (REV3.md)
   wire        cb_we;               // ... the core sets it on call ix / jmp ix / ret / rets
   wire [6:0]  cb_val;
   wire        core_i_kfetch;
   wire [6:0]  core_i_kbank;        // lda (ix++): the bank in IX[22:16]
   wire [20:0] core_i_paddr;

   // The code space (RESPIN 22, REV3.md; lisa_periph.v register 0x15): the
   // upper 16K words is a window on one of 128 code banks (CB, 7 bits): a
   // fetch above word 0x4000 goes to code_bank, below it to bank 0, common
   // to all; CB follows call ix / jmp ix / ret / rets (the bank is in the
   // pointer and the return address).  lda (ix++) reads the word at IX[15:1]
   // of the bank in IX[22:16], by the same window rule.  The data space is
   // flat: the core's 23-bit address, 8 MB.  Reset CB = 1: the TT07 layout.
   assign core_i_paddr = core_i_kfetch ? {core_i_addr[14] ? core_i_kbank : 7'h0, core_i_addr[13:0]} :
                                         {core_i_addr[14] ? code_bank    : 7'h0, core_i_addr[13:0]};

   // ==========================================================================
   // Instantiate the Lisa Processor Core
   // ==========================================================================
   lisa_core i_lisa_core
   (
`ifdef USE_POWER_PINS
      .VPWR(VPWR),
      .VGND(VGND),
`endif
      .clk                       ( clk                       ),
      .rst_n                     ( rst_n_r[2]                ),
      .rst_async_n               ( rst_async_n_r[2]          ),
      .reset                     ( dbg_reset                 ),
                                                             
      // Instruction bus                                     
      .inst_i                    ( core_inst                 ),
      .inst_ready                ( core_i_ready              ),
      .i_fetch                   ( core_i_fetch              ),
      .i_addr                    ( core_i_addr               ),
      .i_kfetch                  ( core_i_kfetch             ),
      .i_kbank                   ( core_i_kbank              ),
      .code_bank                 ( code_bank                 ),
      .cb_we                     ( cb_we                     ),
      .cb_val                    ( cb_val                    ),
      .inst_o                    ( core_inst_o               ),
      .inst_we                   ( core_inst_we              ),
                                                             
      // Data bus                                            
      .d_i                       ( d_i                       ),
      .d_o                       ( d_o_c                     ),
      .d_addr                    ( d_addr_c                  ),
      .d_periph                  ( d_periph_c                ),
      .d_we                      ( d_we_c                    ),
      .d_rd                      ( d_rd_c                    ),
      .d_valid                   ( d_valid_c                 ),
      .d_ready                   ( d_ready & d_addr_good     ),

      .int_i                     ( int_vec                   ),
      .int_en                    ( {1'b1, int_en_vec}        ),   // Timer 3 gates its request with its own IE
                                                             
      // Debug bus                                           
      .dbg_a                     ( dbg_a                     ),
      .dbg_di                    ( dbg_di                    ),
      .dbg_do                    ( dbg_do_lisa               ),
      .dbg_we                    ( dbg_we                    ),
      .dbg_rd                    ( dbg_rd                    ),
      .dbg_ready                 ( dbg_ready_lisa            ),
      .dbg_halted                ( dbg_halted                )
   );

   // ==========================================================================
   // Register the LISA core data bus output to improve timing
   // ==========================================================================
   reg [7:0]  d_o_r;
   reg [22:0] d_addr_r;
   reg        d_valid_r;
   reg        d_we_r;
   reg        d_rd_r;
   reg        d_periph_r;

   assign d_addr_good = d_addr_c == d_addr_r;

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         d_o_r       <= 8'h0;
         d_addr_r    <= 23'h0;
         d_valid_r   <= 1'b0;
         d_we_r      <= 1'b0;
         d_rd_r      <= 1'b0;
         d_periph_r  <= 1'b0;
      end
      else
      begin
         d_o_r       <= d_o_c;
         d_addr_r    <= d_addr_c;
         d_valid_r   <= d_valid_c;
         d_we_r      <= d_we_c;
         d_rd_r      <= d_rd_c;
         d_periph_r  <= d_periph_c;
      end
   end

   assign d_o      = d_o_r;
   assign d_addr   = d_addr_r;
   assign d_valid  = d_valid_r;
   assign d_we     = d_we_r;
   assign d_rd     = d_rd_r;
   assign d_periph = d_periph_r;

   // ==========================================================================
   // Instantiate the INST CACHE controller
   // ==========================================================================
   inst_stream i_inst_stream
   (
      .clk                       ( clk                       ),
      .rst_n                     ( rst_n_r[2]                ),
                                                             
      // Instruction bus                                     
      .core_i_addr               ( core_i_paddr              ),
      .core_inst                 ( core_inst                 ),
      .core_inst_i               ( core_inst_o               ),
      .core_inst_we              ( core_inst_we              ),
      .core_i_fetch              ( core_i_fetch              ),
      .core_i_ready              ( core_i_ready              ),
                                                             
      // Interface to the QSPI controller                    
      .qspi_addr                 ( lisa1_word_addr           ),
      .qspi_rdata                ( lisa1_rdata               ),
      .qspi_wdata                ( lisa1_wdata               ),
      .qspi_wstrb                ( lisa1_wstrb               ),
      .qspi_ready                ( lisa1_ready               ),
      .qspi_ready_ack            ( lisa1_ready_ack           ),
      .qspi_xfer_done            ( lisa1_xfer_done           ),
      .qspi_valid                ( lisa1_valid               ),
      .qspi_xfer_len             ( lisa1_xfer_len            ),
      .qspi_stream               ( lisa1_stream              ),
      .qspi_yield                ( lisa1_yield               ),

      .inst_cache_invalidate     ( inst_cache_invalidate     ),
      .inst_cache_invalidate_ack ( inst_cache_invalidate_ack )
   );

   // ==========================================================================
   // Instantiate the DATA CACHE controller
   // ==========================================================================
   data_cache i_data_cache
   (
      .clk                       ( clk                       ),
      .rst_n                     ( rst_n_r[2]                ),
      .disabled                  ( cache_disabled            ),
                                                             
      // The data bus connection to LISA core                
      .d_addr                    ( d_addr                    ),
      .d_i                       ( d_o                       ),
      .d_o                       ( d_i_cache                 ),
      .d_valid                   ( d_valid                   ),
      .d_we                      ( d_we                      ),
      .d_periph                  ( d_periph                  ),
      .d_ready                   ( d_ready                   ),
                                                             
      // Interface to the RAM32 macro                        
      .ram_we                    ( ram_we                    ),
      .ram_en                    ( ram_en                    ),
      .ram_a                     ( ram_a                     ),
      .ram_di                    ( ram_do                    ),
      .ram_do                    ( ram_di                    ),
      
      // Selects the upper bit for CACHE line mapping
      .cache_map_sel             ( cache_map_sel             ), 
      .data_cache_flush          ( data_cache_flush          ),
      .data_cache_flush_ack      ( data_cache_flush_ack      ),
      .data_cache_invalidate     ( data_cache_invalidate     ),
      .data_cache_invalidate_ack ( data_cache_invalidate_ack ),

      // Interface to the QSPI controller
      .qspi_addr                 ( cache_addr                ),
      .qspi_rdata                ( lisa2_rdata               ),
      .qspi_wdata                ( lisa2_wdata               ),
      .qspi_wstrb                ( lisa2_wstrb               ),
      .qspi_ready                ( lisa2_ready               ),
      .qspi_ready_ack            ( lisa2_ready_ack           ),
      .qspi_xfer_done            ( lisa2_xfer_done           ),
      .qspi_valid                ( lisa2_valid               ),
      .qspi_xfer_len             ( lisa2_xfer_len            )
   );
   assign lisa2_addr = { lisa2_base_addr, 8'h0 } | {1'b0, cache_addr};

   // ==========================================================================
   // Instantiate the DATA RAM
   // ==========================================================================
   RAM32 ram1
   (
`ifdef USE_POWER_PINS
      .VPWR(VPWR),
      .VGND(VGND),
`endif
      .CLK                       ( clk                       ),
      .WE0                       ( ram_we                    ),
      .EN0                       ( ram_en                    ),
      .A0                        ( ram_a                     ),
      .Di0                       ( ram_di                    ),
      .Do0                       ( ram_do                    )
   );
   assign d_i = d_periph ? d_i_periph : d_i_cache;

   // ==========================================================================
   // Instantiate a peripheral controller
   // ==========================================================================
   lisa_periph i_lisa_periph
   (
      .clk                       ( clk                       ),
      .rst_n                     ( rst_n_r[2]                ),
`ifdef WANT_UART2
      .rst_async_n               ( rst_async_n_r[2]          ),
`endif
                                                             
      // Data bus                                            
      .d_i                       ( d_o                       ),
      .d_o                       ( d_i_periph                ),
      .d_addr                    ( d_addr[6:0]               ),
      .d_periph                  ( d_periph                  ),
      .d_we                      ( d_we                      ),
      .d_rd                      ( d_rd                      ),
      .code_bank                 ( code_bank                 ),
      .cb_we                     ( cb_we                     ),
      .cb_val                    ( cb_val                    ),
                                                             
      // GPIO signals                                        
      .porta_in                  ( porta_in                  ),
      .portb                     ( portb                     ),
      .portc                     ( portc                     ),
      .portc_in                  ( portc_in                  ),
      .portc_dir                 ( portc_dir                 ),
      .portd_in                  ( ttlc_to_lisa              ),
      .porte                     ( lisa_to_ttlc              ),

      .int_o                     ( int_vec                   ),
      .int_en                    ( int_en_vec                ),
      .ttlc_int                  ( ttlc_int                  ),
                                                             
      // UART signals                                        
      .uart_tx_d                 ( lisa_tx_d                 ),
      .uart_tx_wr                ( lisa_tx_wr                ),
      .uart_rx_rd                ( lisa_rx_rd                ),
      .uart_rx_d                 ( lisa_rx_d                 ),
      .uart_rx_data_avail        ( lisa_rx_data_avail        ),
      .uart_tx_buf_empty         ( lisa_tx_buf_empty         ),
      .uart_rx_overrun           ( lisa_rx_overrun           ),

`ifdef WANT_UART2
      .uart2_rx                  ( uart2_rx                  ),
      .uart2_tx                  ( uart2_tx                  ),
`endif
                                                             
      // I2C signals                                         
      .scl_pad_i                 ( scl_pad_i                 ),
      .scl_pad_o                 ( scl_pad_o                 ),
      .scl_padoen_o              ( scl_padoen_o              ),
      .sda_pad_i                 ( sda_pad_i                 ),
      .sda_pad_o                 ( sda_pad_o                 ),
      .sda_padoen_o              ( sda_padoen_o              ),

      // SPI master (RESPIN 29)
      .spi_miso_in               ( {ui_in[7], ui_in[2:0]}    ),
      .spi_sclk                  ( spi_sclk                  ),
      .spi_sclk_m3               ( spi_sclk_m3               ),
      .spi_mosi                  ( spi_mosi                  ),
      .spi_cs_n                  ( spi_cs_n                  ),
      .ttlc_scan_req             ( ttlc_scan_req             ),
      .ttlc_scan_busy            ( io_busy                   ),
      .spi_owned                 ( spi_owned                 ),
      .ttlc_idx                  ( ttlcio_idx                ),
      .ttlc_wdata                ( ttlcio_wdata              ),
      .ttlc_we                   ( ttlcio_we                 ),
      .ttlc_rdata                ( ttlcio_rdata              ),
      .ttlc_lisa_start           ( ttlc_lisa_start           ),
      .t3_cap_in                 ( ui_in[5:4]                ),
      .t3_pwm                    ( t3_pwm                    ),
      .t3_pwm_oe                 ( t3_pwm_oe                 ),
      .ws_pixels                 ( output_pins               ),
      .ws_en                     ( ws_en                     ),
      .ws_pins                   ( ws_pins                   ),
      .ws_grp                    ( ws_grp                    ),
      .ws_grp_valid              ( ws_grp_valid              ),
      .ws_fetch_idle             ( ws_fetch_idle             ),
      .ws_flush_ack              ( data_cache_flush_ack || cache_disabled ),
      .ws_flush_req              ( ws_flush_req              ),
      .ws_dma_fetch              ( ws_dma_fetch              ),
      .ws_restart                ( ws_restart                ),
      .ws_adv                    ( ws_adv                    ),
      .ws_last_grp               ( ws_last_grp               ),
      .ws_base                   ( ws_base                   )
   );

   // ==========================================================================
   // Instantiate the QSPI controller / arbiter
   // ==========================================================================
   lisa_qspi_controller i_lisa_qspi_controller
   (
      .clk                       ( clk                       ),
      .rst_n                     ( rst_n_r[2]                ),

      // Interface for debug
      .debug_addr                ( debug_addr                ), // 8Mx32
      .debug_rdata               ( debug_rdata               ), // Read data
      .debug_wdata               ( debug_wdata               ), // Data to write
      .debug_wstrb               ( debug_wstrb               ), // Which bytes in the 32-bits to write
      .debug_ready               ( debug_ready               ), // Next 32-bit value is ready
      .debug_ready_ack           ( debug_ready_ack           ), // Indicates a valid request
      .debug_valid               ( debug_valid               ), // Indicates a valid request
      .debug_xfer_len            ( debug_xfer_len            ), // Number of 32-bit words to transfer
      .debug_ce_ctrl             ( debug_ce_ctrl             ),
      .debug_custom_spi_cmd      ( dbg_custom_spi_cmd        ),
      .debug_cmd_quad_write      ( dbg_cmd_quad_write        ),

      // Interface for Lisa core instruction bus
      .lisa1_addr                ( lisa1_addr                ), // 8Mx32
      .lisa1_rdata               ( lisa1_rdata               ), // Read data
      .lisa1_wdata               ( lisa1_wdata               ), // Data to write
      .lisa1_wstrb               ( lisa1_wstrb               ), // Which bytes in the 32-bits to write
      .lisa1_ready               ( lisa1_ready               ), // Next 32-bit value is ready
      .lisa1_ready_ack           ( lisa1_ready_ack           ), // Next 32-bit value is ready
      .lisa1_xfer_done           ( lisa1_xfer_done           ), // Total xfer_len transfer is done
      .lisa1_valid               ( lisa1_valid               ), // Indicates a valid request
      .lisa1_xfer_len            ( lisa1_xfer_len            ), // Number of 32-bit words to transfer
      .lisa1_ce_ctrl             ( lisa1_ce_ctrl             ),
      .lisa1_stream              ( lisa1_stream              ), // Keep its burst open
      .lisa1_yield               ( lisa1_yield               ), // ... another client waits

      // Interface for Lisa core data bus
      .lisa2_addr                ( lisa2_addr                ), // 8Mx32
      .lisa2_rdata               ( lisa2_rdata               ), // Read data
      .lisa2_wdata               ( lisa2_wdata               ), // Data to write
      .lisa2_wstrb               ( lisa2_wstrb               ), // Which bytes in the 32-bits to write
      .lisa2_ready               ( lisa2_ready               ), // Next 32-bit value is ready
      .lisa2_ready_ack           ( lisa2_ready_ack           ), // Next 32-bit value is ready
      .lisa2_xfer_done           ( lisa2_xfer_done           ), // Total xfer_len transfer is done
      .lisa2_valid               ( lisa2_valid               ), // Indicates a valid request
      .lisa2_xfer_len            ( lisa2_xfer_len            ), // Number of 32-bit words to transfer
      .lisa2_ce_ctrl             ( lisa2_ce_ctrl             ),

      // Interface for Lisa core instruction bus
      .ttlc_addr                 ( ttlc_addr                 ), // 8Mx32
      .ttlc_rdata                ( ttlc_rdata                ), // Read data
      .ttlc_wdata                ( ttlc_wdata                ), // Data to write
      .ttlc_wstrb                ( ttlc_wstrb                ), // Which bytes in the 32-bits to write
      .ttlc_ready                ( ttlc_ready                ), // Next 32-bit value is ready
      .ttlc_ready_ack            ( ttlc_ready_ack            ), // Next 32-bit value is ready
      .ttlc_xfer_done            ( ttlc_xfer_done            ), // Total xfer_len transfer is done
      .ttlc_valid                ( ttlc_valid                ), // Indicates a valid request
      .ttlc_xfer_len             ( ttlc_xfer_len             ), // Number of 32-bit words to transfer
      .ttlc_ce_ctrl              ( ws_dma_fetch ? lisa2_ce_ctrl : ttlc_ce_ctrl ),  // RESPIN 35: the DMA on the data select

      // Interface to the qqspi controller
      .addr                      ( addr                      ), // 8Mx32
      .rdata                     ( rdata                     ), // Read data
      .wdata                     ( wdata                     ), // Data to write
      .wstrb                     ( wstrb                     ), // Which bytes in the 32-bits to write
      .ready                     ( ready                     ), // Next 32-bit value is ready
      .ready_ack                 ( ready_ack                 ), // Next 32-bit value is ready
      .xfer_done                 ( xfer_done                 ), // Total xfer_len transfer is done
      .valid                     ( valid                     ), // Indicates a valid request
      .xfer_len                  ( xfer_len                  ), // Number of 32-bit words to transfer
      .ce_ctrl                   ( ce_ctrl                   ),
      .custom_spi_cmd            ( custom_spi_cmd            ),
      .cmd_quad_write            ( cmd_quad_write            ),
      .stream                    ( stream                    )  // The active client's burst goes on
   );

   // ==========================================================================
   // Instantiate the QQSPI controller
   // ==========================================================================
   lisa_qqspi i_lisa_qqspi
   (
      .clk                       ( clk                       ),
      .rst_n                     ( rst_n_r[2]                ),
     
      // The control interface
      .addr                      ( addr                      ), // 8Mx32
      .rdata                     ( rdata                     ), // Read data
      .wdata                     ( wdata                     ), // Data to write
      .wstrb                     ( wstrb                     ), // Which bytes in the 32-bits to write
      .ready                     ( ready                     ), // Next 32-bit value is ready
      .ready_ack                 ( ready_ack                 ), // Next 32-bit value is ready
      .xfer_done                 ( xfer_done                 ), // Total xfer_len transfer is done
      .valid                     ( valid                     ), // Indicates a valid request
      .xfer_len                  ( xfer_len                  ), // Number of 32-bit words to transfer
      .stream                    ( stream                    ), // The burst goes on
     
      // Per chip-select controls
      .ce_ctrl                   ( ce_ctrl                   ),
      .addr_16b                  ( addr_16b                  ),
      .is_flash                  ( is_flash                  ),
      .quad_mode                 ( quad_mode                 ),
      .spi_clk_div               ( spi_clk_div               ),
      .spi_ce_delay              ( spi_ce_delay              ),
      .spi_mode                  ( spi_mode                  ),
      .spi_rd_late               ( spi_rd_late               ),
     
      // The QSPI Pin interface
      .sclk                      ( sclk                      ),
      .sio0_si_mosi_i            ( sio0_si_mosi_i            ),
      .sio1_so_miso_i            ( sio1_so_miso_i            ),
      .sio2_i                    ( sio2_i                    ),
      .sio3_i                    ( sio3_i                    ),
      .sio0_si_mosi_o            ( sio0_si_mosi_o            ),
      .sio1_so_miso_o            ( sio1_so_miso_o            ),
      .sio2_o                    ( sio2_o                    ),
      .sio3_o                    ( sio3_o                    ),
      .sio_oe                    ( sio_oe                    ),
      .ce                        ( ce                        ),
      .dummy_read_cycles         ( dummy_read_cycles         ),
      .custom_spi_cmd            ( custom_spi_cmd            ),
      .cmd_quad_write            ( cmd_quad_write            )
   );

   // ==========================================================================
   // Instantiate the debug controller
   // ==========================================================================
   debug_ctrl i_debug_ctrl
   (
      .clk                       ( clk                       ),
      .rst_n                     ( rst_n_r[2]                ),
      .rst_async_n               ( rst_async_n_r[2]          ),
                                                             
      // UART signals                                        
      .debug_rx                  ( debug_rx                  ),
      .debug_tx                  ( debug_tx                  ),

      // Processor debug interface
      .debug_a                   ( dbg_a                     ),
      .debug_dout                ( dbg_di                    ),
      .debug_din                 ( dbg_do                    ),
      .debug_wr                  ( dbg_we                    ),
      .debug_rd                  ( dbg_rd                    ),
      .debug_reset               ( dbg_reset                 ),
      .debug_ready               ( dbg_ready                 ),
      .debug_halted              ( dbg_halted                ),
                                                
      // Baud rate manual set control
      .brg_wr                    ( brg_wr                    ),
      .brg_div                   ( brg_div                   ),
      .baud_set                  ( baud_set                  ),
      .baud_div                  ( baud_div                  ),
      .baud_ref                  ( baud_ref                  ),

      // Signals to share UART with Lisa core
      .plus_guard_time           ( plus_guard_time           ),
      .lisa_tx_d                 ( lisa_tx_d                 ),
      .lisa_tx_wr                ( lisa_tx_wr                ),
      .lisa_rx_rd                ( lisa_rx_rd                ),
      .lisa_rx_d                 ( lisa_rx_d                 ),
      .lisa_rx_data_avail        ( lisa_rx_data_avail        ),
      .lisa_tx_buf_empty         ( lisa_tx_buf_empty         ),
      .lisa_rx_overrun           ( lisa_rx_overrun           )
   );

   // ==========================================================================
   // Instantiate the debug registers
   // ==========================================================================
   debug_regs i_debug_regs
   (
`ifdef USE_POWER_PINS
      .VPWR(VPWR),
      .VGND(VGND),
`endif
      // Timing and reset inputs
      .clk                       ( clk                       ), // System clock
      .rst_n                     ( rst_n_r[2]                ), // Active low reset

      // The Debug ctrl interface
      .dbg_a                     ( dbg_a                     ),
      .dbg_di                    ( dbg_di                    ),
      .dbg_do                    ( dbg_do_regs               ),
      .dbg_we                    ( dbg_we                    ),
      .dbg_rd                    ( dbg_rd                    ),
      .dbg_ready                 ( dbg_ready_regs            ),

      // The Debug ctrl interface
      .debug_addr                ( debug_addr                ), // 8Mx32
      .debug_rdata               ( debug_rdata               ), // Read data
      .debug_wdata               ( debug_wdata               ), // Data to write
      .debug_wstrb               ( debug_wstrb               ), // Which bytes in the 32-bits to write
      .debug_ready               ( debug_ready               ), // Next 32-bit value is ready
      .debug_valid               ( debug_valid               ), // Indicates a valid request
      .debug_xfer_len            ( debug_xfer_len            ), // Number of 16-bit words to transfer
      .debug_ce_ctrl             ( debug_ce_ctrl             ),

      // Lisa core QSPI CE and base addresses
      .lisa1_ce_ctrl             ( lisa1_ce_ctrl             ),
      .lisa1_base_addr           ( lisa1_base_addr           ),
      .lisa2_ce_ctrl             ( lisa2_ce_ctrl             ),
      .lisa2_base_addr           ( lisa2_base_addr           ),

      // TTLC core QSPI CE and base addresses                 
      .ttlc_ce_ctrl              ( ttlc_ce_ctrl              ),
      .ttlc_base_addr            ( ttlc_base_addr            ),

      // QSPI Chip Enable options
      .addr_16b                  ( addr_16b                  ),
      .is_flash                  ( is_flash                  ),
      .quad_mode                 ( quad_mode                 ),
      .dummy_read_cycles         ( dummy_read_cycles         ),
                                                             
      .custom_spi_cmd            ( dbg_custom_spi_cmd        ),
      .cmd_quad_write            ( dbg_cmd_quad_write        ),
      .plus_guard_time           ( plus_guard_time           ),
      .spi_clk_div               ( spi_clk_div               ),
      .spi_ce_delay              ( spi_ce_delay              ),
      .spi_mode                  ( spi_mode                  ),
      .spi_rd_late               ( spi_rd_late               ),
                                                             
      // I/O Mux Bits                                        
      .output_mux_bits           ( output_mux_bits           ),
      .io_mux_bits               ( io_mux_bits               ),
      .psram_mod                 ( psram_mod                 ),

      // Cache control
      .cache_disabled            ( cache_disabled            ),
      .cache_map_sel             ( cache_map_sel             ),

      .data_cache_flush          ( dbg_cache_flush           ),
      .data_cache_flush_ack      ( data_cache_flush_ack      ),
      .data_cache_invalidate     ( data_cache_invalidate     ),
      .data_cache_invalidate_ack ( data_cache_invalidate_ack ),
      .inst_cache_invalidate     ( inst_cache_invalidate     ),
      .inst_cache_invalidate_ack ( inst_cache_invalidate_ack ),
      .ttlc_cache_invalidate     ( ttlc_cache_invalidate     ),
      .ttlc_cache_invalidate_ack ( ttlc_cache_invalidate_ack ),
      .clk_div                   ( clk_div                   ),

      // TTLC Debug signals
      .ttlc_pc                   ( mc14500_pc                ),
      .ttlc_exec                 ( ttlc_exec                 ),
      .ttlc_halt                 ( ttlc_halt                 ),
      .ttlc_reset                ( ttlc_reset                ),
      .ttlc_shiftclk             ( ttlc_shiftclk             ),
      .ttlc_i_ready              ( ttlc_i_ready              ),
      .ttlc_data_in              ( DATA                      ),
      .ttlc_data_out             ( DATA_OUT                  ),
      .ttlc_result_reg           ( RR                        )
   );

   assign dbg_do         = dbg_do_lisa | dbg_do_regs;
   assign dbg_ready      = dbg_ready_lisa | dbg_ready_regs;
   assign lisa1_addr     = {lisa1_base_addr, 8'h0} | {2'h0, lisa1_word_addr, 1'b0};
   // the TTLC's fetch, or the WS2812B driver's DMA (RESPIN 35): its buffer
   // is a data address (BASE x 256 + the group's offset, an add: a frame
   // passes 256 bytes) on the data cache's base and select
   assign ttlc_addr      = ws_dma_fetch ?
                           ({lisa2_base_addr, 8'h0} | ({ws_base, 8'h0} + {9'h0, ttlc_fetch_word, 1'b0})) :
                           ({ttlc_base_addr, 8'h0} | {9'h0, ttlc_fetch_word, 1'b0});
   assign data_cache_flush = dbg_cache_flush | ws_flush_req;
   assign baud_div       = ui_in[6:0];
   assign baud_set       = ui_in[7];
   assign debug_ready_ack= 1'b1;

   always @(posedge clk or negedge rst_async_n_r[2])
   begin
      if (~rst_async_n_r[2])
      begin
         rx1_r1 <= 1'b0;
         rx2_r1 <= 1'b0;
         rx3_r1 <= 1'b0;
         rx1_r2 <= 1'b0;
         rx2_r2 <= 1'b0;
         rx3_r2 <= 1'b0;
      end
      else
      begin
         rx1_r1 <= ui_in[3];
         rx1_r2 <= rx1_r1;
         rx2_r1 <= uio_in[6];
         rx2_r2 <= rx2_r1;
         rx3_r1 <= uio_in[4];
         rx3_r2 <= rx3_r1;
      end
   end

   // ==========================================================================
   // Instantiate the autobaud detector
   // ==========================================================================
   debug_autobaud i_debug_autobaud
   (
      // Timing and reset inputs
      .clk                       ( clk                       ), // System clock
      .rst_n                     ( rst_async_n_r[2]          ), // Active low reset
      .disabled                  ( ui_in[7]                  ), // Disabled if set externally
      .rx1                       ( rx1_r2                    ), // Input from the UART
      .rx2                       ( rx2_r2                    ), // Input from the UART
      .rx3                       ( rx3_r2                    ), // Input from the UART
      .wr                        ( brg_wr                    ), // Write the baud rate
      .div                       ( brg_div                   ), // The divisor
      .rx_sel                    ( rx_sel                    )  // Selected RX input
   );

   // ==========================================================================
   // Instantiate the Lisa I/O Mux module
   // ==========================================================================
   lisa_io_mux i_lisa_io_mux
   (
      .clk                       ( clk                       ),
      .rst_n                     ( rst_n_r[2]                ),
      .ena                       ( ena                       ),

      // Chip top I/O signals
      .ui_in                     ( ui_in                     ),
      .uo_out                    ( uo_out                    ),
      .uio_in                    ( uio_in                    ),
      .uio_out                   ( uio_out                   ),
      .uio_oe                    ( uio_oe                    ),

      // I/O mux controls
      .rx_sel                    ( rx_sel                    ),
      .output_mux_bits           ( output_mux_bits           ),
      .io_mux_bits               ( io_mux_bits               ),
      .psram_mod                 ( psram_mod                 ),

      // Debug UART signals
      .rx1                       ( rx1_r2                    ), // Input from the UART
      .rx2                       ( rx2_r2                    ), // Input from the UART
      .rx3                       ( rx3_r2                    ), // Input from the UART

      // UART2 signals
`ifdef WANT_UART2
      .uart2_rx                  ( uart2_rx                  ),
      .uart2_tx                  ( uart2_tx                  ),
`endif

      // QSPI I/O signals
      .sclk                      ( sclk                      ),
      .ce                        ( ce                        ),
      .sio0_si_mosi_i            ( sio0_si_mosi_i            ),
      .sio1_so_miso_i            ( sio1_so_miso_i            ),
      .sio2_i                    ( sio2_i                    ),
      .sio3_i                    ( sio3_i                    ),
      .sio0_si_mosi_o            ( sio0_si_mosi_o            ),
      .sio1_so_miso_o            ( sio1_so_miso_o            ),
      .sio2_o                    ( sio2_o                    ),
      .sio3_o                    ( sio3_o                    ),
      .sio_oe                    ( sio_oe                    ),

      // Lisa parallel port signals
      .lisa_porta_o              ( porta_in                  ),
      .lisa_portb_i              ( portb                     ),
      .lisa_portc_i              ( portc                     ),
      .lisa_portc_dir_i          ( portc_dir                 ),
      .lisa_portc_o              ( portc_in                  ),
                                                             
      // Lisa parallel port signals
      .ttlc_io_latch             ( ttlc_io_latch             ),
      .ttlc_io_shiftclk          ( ttlc_io_shiftclk          ),
      .ttlc_out_data             ( ttlc_out_data             ),
      .ttlc_in_data              ( ttlc_in_data              ),
      .spi_sclk                  ( spi_sclk                  ),
      .spi_sclk_m3               ( spi_sclk_m3               ),
      .spi_mosi                  ( spi_mosi                  ),
      .spi_cs_n                  ( spi_cs_n                  ),
      .spi_owned                 ( spi_owned & !io_busy      ),   // a scan has the data pins (RESPIN 30)
      .t3_pwm                    ( t3_pwm                    ),
      .t3_pwm_oe                 ( t3_pwm_oe                 ),
      .ws_en                     ( ws_en                     ),
      .ws_pins                   ( ws_pins                   ),
      .ttlc_reset                ( ttlc_reset                ),
      .ttlc_shiftclk             ( ttlc_shiftclk             ),

      // UART inputs                                         
      .baud_ref                  ( baud_ref                  ),
      .debug_tx                  ( debug_tx                  ),
                                                             
      // I2C signals                                         
      .scl_pad_i                 ( scl_pad_i                 ),
      .scl_pad_o                 ( scl_pad_o                 ),
      .scl_padoen_o              ( scl_padoen_o              ),
      .sda_pad_i                 ( sda_pad_i                 ),
      .sda_pad_o                 ( sda_pad_o                 ),
      .sda_padoen_o              ( sda_padoen_o              ),
                                                             
      // Muxed outputs                                       
      .debug_rx                  ( debug_rx                  ) 
   );

   // ==========================================================================
   // The TTLC's PC and stack are in ttlc_fetch; io_busy_r holds the core a
   // clock after a scan
   // ==========================================================================
   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         io_busy_r      <= 1'b0;
         ttlc_scan_pend <= 1'b0;
      end
      else
      begin
         io_busy_r      <= io_busy;
         ttlc_scan_pend <= ttlc_scan_req & spi_owned;
      end
   end

   // The interlock with the SPI master (RESPIN 29): while it owns the mode-3
   // pins (uo[2:0] carry its MOSI and selects) a scan the nopo requests is
   // held - FLAG_O is a pulse, ttlc_scan_pend keeps it - and so is the ICU;
   // the scan starts the clock the pins come back.  The SPI is granted them
   // only with no scan running or requested.
   assign ttlc_scan_req = FLAG_O | ttlc_scan_pend;

   // ==========================================================================
   // Instantiate the MC14500B core
   // ==========================================================================
   mc14500b i_mc14500b
   (
      .clk                       ( clk                       ),
      .RST                       ( !rst_n_r[2]               ),
      .DATA                      ( DATA                      ),
      .I0                        ( ttlc_inst[0]              ),
      .I1                        ( ttlc_inst[1]              ),
      .I2                        ( ttlc_inst[2]              ),
      .I3                        ( ttlc_inst[3]              ),
      .run                       ( mc14500_run               ),
      .WRITE                     ( WRITE                     ),
      .DATA_OUT                  ( DATA_OUT                  ),
      .RR                        ( RR                        ),
      .JMP                       ( JMP                       ),
      .RTN                       ( RTN                       ),
      .FLAG_O                    ( FLAG_O                    ),
      .FLAG_F                    ( FLAG_F                    )
   );

   // ==========================================================================
   // Instantiate the INST CACHE controller
   // ==========================================================================
   ttlc_fetch i_ttlc_fetch
   (
      .clk                       ( clk                       ),
      .rst_n                     ( rst_n_r[2]                ),
      .fetch_en                  ( ws_dma_fetch || !ttlc_halt ),
      .run                       ( mc14500_run               ),
      .jmp                       ( JMP                       ),
      .rtn                       ( RTN                       ),
      .flag_f                    ( FLAG_F                    ),
      .inst                      ( ttlc_inst                 ),
      .ready                     ( ttlc_i_ready              ),
      .exec                      ( ttlc_exec                 ),
      .pc                        ( mc14500_pc                ),
      .fetch_word                ( ttlc_fetch_word           ),
      .qspi_rdata                ( ttlc_rdata                ),
      .qspi_wdata                ( ttlc_wdata                ),
      .qspi_wstrb                ( ttlc_wstrb                ),
      .qspi_ready                ( ttlc_ready                ),
      .qspi_ready_ack            ( ttlc_ready_ack            ),
      .qspi_xfer_done            ( ttlc_xfer_done            ),
      .qspi_valid                ( ttlc_valid                ),
      .qspi_xfer_len             ( ttlc_xfer_len             ),
      .invalidate                ( ttlc_cache_invalidate     ),
      .invalidate_ack            ( ttlc_cache_invalidate_ack ),
      .ws_mode                   ( ws_dma_fetch              ),
      .ws_restart                ( ws_restart                ),
      .ws_adv                    ( ws_adv                    ),
      .ws_last_grp               ( ws_last_grp               ),
      .group_a                   ( ws_grp                    ),
      .group_a_valid             ( ws_grp_valid              ),
      .fetch_idle                ( ws_fetch_idle             )
   );

   // The core takes the presented slot when nothing holds it: an I/O scan
   // (and the clock after), the debugger, or the scan a nopo just started
   assign mc14500_run  = ttlc_i_ready && !io_busy && !io_busy_r && !ttlc_halt && !FLAG_O && !ttlc_scan_pend &&
                         !ws_dma_fetch;

   // ==========================================================================
   // I/O for the MC14500B
   // ==========================================================================
   ttlc_io i_ttlc_io
   (
      .clk                       ( clk                       ), // Clock signal
      .rst                       ( !rst_n_r[2]               ), // Synchronous reset input
      .address                   ( address[7:0]              ), // 12-bit address bus
      .mem_write                 ( mem_write                 ), // Memory write enable
      .data_in                   ( data_in                   ), // Data input for writes
      .rr_value                  ( rr_value                  ), // RR output from MC14500B
      .input_pins                ( input_pins                ), // External input pins
      .output_pins               ( output_pins               ), // Driven from internal registers, renumbered
      .data_out                  ( data_out                  ), // Data output pin, continuously assigned
      .port_out                  ( ttlc_to_lisa              ),
      .port_in                   ( lisa_to_ttlc              ),
      .ttlc_int                  ( ttlc_int                  ),
      .lisa_idx                  ( ttlcio_idx                ),
      .lisa_wdata                ( ttlcio_wdata              ),
      .lisa_we                   ( ttlcio_we                 ),
      .lisa_rdata                ( ttlcio_rdata              )
   );

   assign rr_value  = RR;
   assign mem_write = WRITE;
   assign data_in   = DATA_OUT;
   assign DATA      = data_out;
   assign address   = {4'h0, ttlc_inst[11:4]};   // the slot's 8-bit I/O address

   // ==========================================================================
   // Instantiate the I/O shift register management module
   // ==========================================================================
   shift_reg_io i_shift_reg_io
   (
      .clk                       ( clk                       ), // System clock
      .rst_n                     ( rst_n_r[2]                ), // System reset
      .data_in                   ( ttlc_in_data              ), // Serial data inputs
      .output_buffer             ( output_pins               ), // Input to the module, drives the serial output
      .clk_div                   ( clk_div                   ), // Clock division factor control  ( 00: /2, 01: /4, 10: /8, 11: /16 )
      .start                     ( ttlc_io_start             ), // Start the I/O transfer
      .io_busy                   ( io_busy                   ), // Indicates I/O transfer complete
      .data_out                  ( ttlc_out_data             ), // Serial data outputs
      .latch                     ( ttlc_io_latch             ), // Latch signal for external register control
      .shift_clk                 ( ttlc_io_shiftclk          ), // Shift clock output for external shift registers
      .input_buffer              ( input_pins                )  // Output from the module, captures the serial input
   );

   // the TTLC's own scans wait while the SPI holds the pins; one the core
   // starts (RESPIN 30) runs even then - the core holds the claim itself
   // and lisa_ttlcio waits for the SPI byte to end
   assign ttlc_io_start = (ttlc_scan_req & !spi_owned) | ttlc_lisa_start;

endmodule // tt_um_pettit_lisa

