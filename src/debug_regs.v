/*
================================================================================
debug_regs:   Debug registers

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

================================================================================
*/

module debug_regs
#(
   parameter CHIP_SELECTS = 2
 )
(
`ifdef USE_POWER_PINS
    input                  VPWR,
    input                  VGND,
`endif
   // Timing and reset inputs
   input  wire                clk,              // System clock 
   input  wire                rst_n,            // Active low reset

   // The Debug ctrl interface
   input  wire [7:0]          dbg_a,
   input  wire [15:0]         dbg_di,
   output reg  [15:0]         dbg_do,
   input  wire                dbg_we,
   input  wire                dbg_rd,
   output wire                dbg_ready,

   // The Debug ctrl interface
   output reg  [23:0]         debug_addr,          // 8Mx32
   input  wire [15:0]         debug_rdata,         // Read data
   output wire [15:0]         debug_wdata,         // Data to write
   output wire [1:0]          debug_wstrb,         // Which bytes in the 32-bits to write
   input  wire                debug_ready,         // Next 32-bit value is ready
   output wire                debug_valid,         // Indicates a valid request 
   output wire [3:0]          debug_xfer_len,      // Number of 16-bit words to transfer
   output reg  [CHIP_SELECTS -1:0]  debug_ce_ctrl,

   output reg  [CHIP_SELECTS -1:0]  lisa1_ce_ctrl,
   output wire [15:0]         lisa1_base_addr,

   output reg  [CHIP_SELECTS -1:0]  lisa2_ce_ctrl,
   output wire [15:0]         lisa2_base_addr,

   output reg  [CHIP_SELECTS -1:0]  ttlc_ce_ctrl,
   output wire [15:0]         ttlc_base_addr,

   output reg  [CHIP_SELECTS-1:0] addr_16b,
   output reg  [CHIP_SELECTS-1:0] is_flash,
   output reg  [CHIP_SELECTS-1:0] quad_mode,
   output reg  [CHIP_SELECTS*4-1:0] dummy_read_cycles,
   output wire                custom_spi_cmd,
   output wire [7:0]          cmd_quad_write,
   output reg  [3:0]          plus_guard_time,
   output wire [3:0]          spi_clk_div,
   output wire [6:0]          spi_ce_delay,
   output wire [1:0]          spi_mode,
   output wire [1:0]          spi_rd_late,     // 0x1E [14:13]: a read bit captured on SCLK's falling edge (RESPIN 34)

   output wire [15:0]         output_mux_bits,
   output wire [7:0]          io_mux_bits,

   output reg                 cache_disabled,
   output reg  [1:0]          cache_map_sel,
   output reg                 data_cache_flush,
   input  wire                data_cache_flush_ack,
   output reg                 data_cache_invalidate,
   input  wire                data_cache_invalidate_ack,
   output reg                 inst_cache_invalidate,
   input  wire                inst_cache_invalidate_ack,
   output reg                 ttlc_cache_invalidate,
   input  wire                ttlc_cache_invalidate_ack,

   output wire [1:0]          clk_div,
   output wire                psram_mod,        // 0x1c bit 10: uio[7:4] for the TT QSPI Pmod

   input  wire [13:0]         ttlc_pc,          // {group, slot} (ttlc_fetch.v)
   input  wire                ttlc_exec,        // the TTLC retires an instruction (its PC moves)
   output wire                ttlc_halt,
   output reg                 ttlc_reset,
   output reg                 ttlc_shiftclk,
   input  wire                ttlc_i_ready,
   input  wire                ttlc_data_in,
   input  wire                ttlc_data_out,
   input  wire                ttlc_result_reg
);

   wire        debug_qspi_write;
   wire        debug_qspi_read;
   reg  [7:0]  cmd_quad_write_r;
   wire [14:0] ttlc_brk_addr0;   // {valid, pc}
   wire [14:0] ttlc_brk_addr1;
   wire [14:0] ttlc_brk_addr2;
   reg         ttlc_step;
   reg         ttlc_run;
   reg         ttlc_skip;        // run / step written: the breakpoint at this PC is passed
   wire        ttlc_brk;
   wire        dbg_addr_12;
   wire        dbg_addr_13;
   wire        dbg_addr_1b;
   wire        dbg_addr_1c;
   wire        dbg_addr_1e;
   wire        dbg_addr_1f;
   wire        dbg_addr_48;
   wire        dbg_addr_49;
   wire        dbg_addr_4a;
   (* keep = "true" *)
   wire        dbg_we_12;
   (* keep = "true" *)
   wire        dbg_we_13;
   (* keep = "true" *)
   wire        dbg_we_1b;
   (* keep = "true" *)
   wire        dbg_we_1c;
   (* keep = "true" *)
   wire        dbg_we_1e;
   (* keep = "true" *)
   wire        dbg_we_1f;
   (* keep = "true" *)
   wire        dbg_we_48;
   (* keep = "true" *)
   wire        dbg_we_49;
   (* keep = "true" *)
   wire        dbg_we_4a;
   wire [10:0] addr_1c_bits;
   wire [14:0] addr_1e_bits;

   // We transfer a single 16-bit value on the debug interface
   assign debug_qspi_write = (dbg_a == 8'h20 || dbg_a == 8'h21) && dbg_we;
   assign debug_qspi_read  = (dbg_a == 8'h20 || dbg_a == 8'h21 || dbg_a == 8'h22) && dbg_rd;
   assign custom_spi_cmd   = dbg_a == 8'h21 || dbg_a == 8'h22;
   assign cmd_quad_write   = dbg_a == 8'h22 ? 8'h05 : cmd_quad_write_r;
   assign debug_xfer_len = 4'h0;    // Zero means 1 16-bit transfer
   assign dbg_ready      = debug_ready || (dbg_a[7:4] != 4'h2 && dbg_a[7:4] != 4'h0 &&
                              (dbg_rd | dbg_we));
   assign debug_valid    = (debug_qspi_write | debug_qspi_read) && !debug_ready;
   assign debug_wdata    = debug_qspi_write ? dbg_di : 16'h0;
   assign debug_wstrb    = {debug_qspi_write, debug_qspi_write};

   assign dbg_addr_12 = dbg_a == 8'h12;
   assign dbg_addr_13 = dbg_a == 8'h13;
   assign dbg_addr_1b = dbg_a == 8'h1b;
   assign dbg_addr_1c = dbg_a == 8'h1c;
   assign dbg_addr_1e = dbg_a == 8'h1e;
   assign dbg_addr_1f = dbg_a == 8'h1f;
   assign dbg_addr_48 = dbg_a == 8'h48;
   assign dbg_addr_49 = dbg_a == 8'h49;
   assign dbg_addr_4a = dbg_a == 8'h4a;

   assign io_mux_bits = addr_1c_bits[7:0];
   assign clk_div     = addr_1c_bits[9:8];
   assign psram_mod   = addr_1c_bits[10];
   assign spi_clk_div = addr_1e_bits[3:0];
   assign spi_ce_delay= addr_1e_bits[10:4];
   assign spi_mode    = addr_1e_bits[12:11];
   assign spi_rd_late = addr_1e_bits[14:13];

   sky130_fd_sc_hd__and2_4 and_12(
      `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
      `endif
         .A(dbg_addr_12), .B(dbg_we), .X(dbg_we_12) );
   sky130_fd_sc_hd__and2_4 and_13(
      `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
      `endif
         .A(dbg_addr_13), .B(dbg_we), .X(dbg_we_13) );
   sky130_fd_sc_hd__and2_4 and_1b(
      `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
      `endif
         .A(dbg_addr_1b), .B(dbg_we), .X(dbg_we_1b) );
   sky130_fd_sc_hd__and2_4 and_1c(
      `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
      `endif
         .A(dbg_addr_1c), .B(dbg_we), .X(dbg_we_1c) );
   sky130_fd_sc_hd__and2_4 and_1e(
      `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
      `endif
         .A(dbg_addr_1e), .B(dbg_we), .X(dbg_we_1e) );
   sky130_fd_sc_hd__and2_4 and_1f(
      `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
      `endif
         .A(dbg_addr_1f), .B(dbg_we), .X(dbg_we_1f) );
   sky130_fd_sc_hd__and2_4 and_48(
      `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
      `endif
         .A(dbg_addr_48), .B(dbg_we), .X(dbg_we_48) );
   sky130_fd_sc_hd__and2_4 and_49(
      `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
      `endif
         .A(dbg_addr_49), .B(dbg_we), .X(dbg_we_49) );
   sky130_fd_sc_hd__and2_4 and_4a(
      `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
      `endif
         .A(dbg_addr_4a), .B(dbg_we), .X(dbg_we_4a) );

   // ===================================================================
   // We are generating latches for most of the static flops
   // ===================================================================
   generate
   genvar b;
      for (b = 0; b < 16; b = b + 1)
      begin : BASE_BITS
         sky130_fd_sc_hd__dlrtp_1   lisa1_base_latch
         (
         `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
         `endif
            .RESET_B    ( rst_n              ),
            .GATE       ( dbg_we_12          ),
            .D          ( dbg_di[b]          ),
            .Q          ( lisa1_base_addr[b] )
         );
         sky130_fd_sc_hd__dlrtp_1   lisa2_base_latch
         (
         `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
         `endif
            .RESET_B    ( rst_n              ),
            .GATE       ( dbg_we_13          ),
            .D          ( dbg_di[b]          ),
            .Q          ( lisa2_base_addr[b] )
         );
         sky130_fd_sc_hd__dlrtp_1   output_mux_latch
         (
         `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
         `endif
            .RESET_B    ( rst_n              ),
            .GATE       ( dbg_we_1b          ),
            .D          ( dbg_di[b]          ),
            .Q          ( output_mux_bits[b] )
         );
         if (b < 11)
         begin : IO_GEN
            sky130_fd_sc_hd__dlrtp_1   io_mux_latch
            (
            `ifdef USE_POWER_PINS
               .VPWR(VPWR),
               .VGND(VGND),
               .VPB(VPWR),
               .VNB(VGND),
            `endif
               .RESET_B    ( rst_n              ),
               .GATE       ( dbg_we_1c          ),
               .D          ( dbg_di[b]          ),
               .Q          ( addr_1c_bits[b]    )
            );
         end
         sky130_fd_sc_hd__dlrtp_1   ttlc_base_latch
         (
         `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
         `endif
            .RESET_B    ( rst_n              ),
            .GATE       ( dbg_we_1f          ),
            .D          ( dbg_di[b]          ),
            .Q          ( ttlc_base_addr[b]  )
         );
      end
      for (b = 0; b < 15; b = b + 1)
      begin : BREAK_BITS
         if (b < 15)
         begin : ADDR_1E
         sky130_fd_sc_hd__dlrtp_1   addr_1e_latch
         (
         `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
         `endif
            .RESET_B    ( rst_n              ),
            .GATE       ( dbg_we_1e          ),
            .D          ( dbg_di[b]          ),
            .Q          ( addr_1e_bits[b]    )
         );
         end
         sky130_fd_sc_hd__dlrtp_1   ttlc_brk0_latch
         (
         `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
         `endif
            .RESET_B    ( rst_n              ),
            .GATE       ( dbg_we_48          ),
            .D          ( dbg_di[b]          ),
            .Q          ( ttlc_brk_addr0[b]  )
         );
         sky130_fd_sc_hd__dlrtp_1   ttlc_brk1_latch
         (
         `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
         `endif
            .RESET_B    ( rst_n              ),
            .GATE       ( dbg_we_49          ),
            .D          ( dbg_di[b]          ),
            .Q          ( ttlc_brk_addr1[b]  )
         );
         sky130_fd_sc_hd__dlrtp_1   ttlc_brk2_latch
         (
         `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
            .VPB(VPWR),
            .VNB(VGND),
         `endif
            .RESET_B    ( rst_n              ),
            .GATE       ( dbg_we_4a          ),
            .D          ( dbg_di[b]          ),
            .Q          ( ttlc_brk_addr2[b]  )
         );
      end
   endgenerate
         
   // ===================================================================
   // The Debug QSPI address register
   // ===================================================================
   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         debug_addr        <= 24'h0;
//         lisa1_base_addr   <= 16'h0;
//         lisa2_base_addr   <= 16'h0;
//         ttlc_base_addr    <= 16'h0;
         lisa1_ce_ctrl     <= {{(CHIP_SELECTS-1){1'b0}}, 1'b1};
         lisa2_ce_ctrl     <= {{(CHIP_SELECTS-1){1'b0}}, 1'b1};
         ttlc_ce_ctrl      <= {{(CHIP_SELECTS-1){1'b0}}, 1'b1};
         debug_ce_ctrl     <= {{(CHIP_SELECTS-1){1'b0}}, 1'b1};
         quad_mode         <= {{(CHIP_SELECTS-1){1'b0}}, 1'b1};
         addr_16b          <= {CHIP_SELECTS{1'b0}};
         is_flash          <= {{(CHIP_SELECTS-1){1'b0}}, 1'b1};
         dummy_read_cycles <= {{((CHIP_SELECTS-1)*4){1'b0}}, 4'ha};
         cmd_quad_write_r  <= 8'h38;
         plus_guard_time   <= 4'h1;
         ttlc_reset        <= 1'b0;
         ttlc_shiftclk     <= 1'b0;
//         output_mux_bits   <= 16'h0;
//         io_mux_bits       <= 8'h0;
         cache_disabled    <= 1'b0;
         cache_map_sel     <= 2'h3;
//         spi_clk_div       <= 4'h0;
//         spi_ce_delay      <= 7'h0;
//         spi_mode          <= 2'h0;
         data_cache_flush  <= 1'b0;
         data_cache_invalidate <= 1'b0;
         inst_cache_invalidate <= 1'b0;
         ttlc_cache_invalidate <= 1'b0;
//         clk_div           <= 2'h0;
//         ttlc_brk_addr0    <= 12'hfff;
//         ttlc_brk_addr1    <= 12'hfff;
         ttlc_run          <= 1'b0;
         ttlc_step         <= 1'b0;
         ttlc_skip         <= 1'b0;
      end
      else
      begin
         if (dbg_a[7:4] == 4'h1 && dbg_we)
         begin
            case (dbg_a[3:0])    
               4'h0: debug_addr[15:0] <= dbg_di;
               4'h1: debug_addr[23:16] <= dbg_di[7:0];
//               4'h2: lisa1_base_addr <= dbg_di;
//               4'h3: lisa2_base_addr <= dbg_di;
               4'h4: lisa1_ce_ctrl <= dbg_di[CHIP_SELECTS -1:0];
               4'h5: {ttlc_ce_ctrl, lisa2_ce_ctrl} <= dbg_di[CHIP_SELECTS*2 -1:0];
               4'h6: debug_ce_ctrl <= dbg_di[CHIP_SELECTS -1:0];
               4'h7: {addr_16b, is_flash, quad_mode} <= dbg_di[CHIP_SELECTS*3-1:0];
               4'h8: dummy_read_cycles <= dbg_di[CHIP_SELECTS*4-1:0];
               4'h9: cmd_quad_write_r <= dbg_di[7:0];
               4'ha: plus_guard_time <= dbg_di[3:0];
//               4'hb: output_mux_bits <= dbg_di;
//               4'hc: {clk_div, io_mux_bits} <= dbg_di[9:0];
               4'hd: {ttlc_cache_invalidate, inst_cache_invalidate, data_cache_invalidate, data_cache_flush,
                        cache_disabled, cache_map_sel} <= dbg_di[6:0];
   
//               4'he: {spi_mode, spi_ce_delay, spi_clk_div} <= dbg_di[12:0];
//               4'hf: ttlc_base_addr <= dbg_di;
               default: begin end
            endcase
         end
         else if (dbg_a == 8'h20 && (dbg_we || dbg_rd) && debug_ready)
            debug_addr <= debug_addr + 24'h2;
         else
         begin
            if (data_cache_flush_ack)
               data_cache_flush <= 1'b0;
            if (data_cache_invalidate_ack)
               data_cache_invalidate <= 1'b0;
            if (inst_cache_invalidate_ack)
               inst_cache_invalidate <= 1'b0;
            if (ttlc_cache_invalidate_ack)
               ttlc_cache_invalidate <= 1'b0;
         end

         if (dbg_a[7:4] == 4'h4 && dbg_we)
         begin
            case (dbg_a[3:0])    
            4'h0: begin
                     // bit 0 run, bit 1 step: one instruction, then halted;
                     // either passes a breakpoint on the current PC
                     {ttlc_shiftclk, ttlc_reset, ttlc_step, ttlc_run} <= dbg_di[3:0];
                     ttlc_skip <= dbg_di[0] | dbg_di[1];
                  end
//            4'h8: ttlc_brk_addr0 <= dbg_di[11:0];
//            4'h9: ttlc_brk_addr1 <= dbg_di[11:0];
            default:
               ;
            endcase
         end
         else
         begin
            // an instruction retired: the step is done (TT07's step bit held
            // the fetch it needed to clear itself), the breakpoint passed
            if (ttlc_exec)
            begin
               ttlc_skip <= 1'b0;
               if (ttlc_step)
               begin
                  ttlc_step <= 1'b0;
                  ttlc_run  <= 1'b0;
               end
            end

            // a breakpoint halts before its instruction (ttlc_halt below);
            // TT07 compared a clock behind the fetch and stopped one late
            if (ttlc_brk && !ttlc_skip && !ttlc_step)
               ttlc_run <= 1'b0;
         end
      end
   end

   // ===================================================================
   // The Debug readback logic
   // ===================================================================
   always @*
   begin
      dbg_do = 16'h0;
      if (dbg_a[7:4] == 4'h1 && dbg_rd == 1'b1)
      begin
         case (dbg_a[3:0])
         4'h0: dbg_do = debug_addr[15:0];
         4'h1: dbg_do = {8'h0, debug_addr[23:16]};
         4'h2: dbg_do = lisa1_base_addr;
         4'h3: dbg_do = lisa2_base_addr;
         4'h4: dbg_do = {{(16-CHIP_SELECTS){1'b0}}, lisa1_ce_ctrl};
         4'h5: dbg_do = {{(16-CHIP_SELECTS*2){1'b0}}, ttlc_ce_ctrl, lisa2_ce_ctrl};
         4'h6: dbg_do = {{(16-CHIP_SELECTS){1'b0}}, debug_ce_ctrl};
         4'h7: dbg_do = {{(16-CHIP_SELECTS*3){1'b0}}, addr_16b, is_flash, quad_mode};
         4'h8: dbg_do = {{(16-CHIP_SELECTS*4){1'b0}}, dummy_read_cycles};
         4'h9: dbg_do = {8'h0, cmd_quad_write_r};
         4'ha: dbg_do = {12'h0, plus_guard_time};
         4'hb: dbg_do = output_mux_bits;
         4'hc: dbg_do = {5'h0, psram_mod, clk_div, io_mux_bits};
         4'hd: dbg_do = {9'h0, ttlc_cache_invalidate, inst_cache_invalidate, data_cache_invalidate,
                         data_cache_flush, cache_disabled, cache_map_sel};
         4'he: dbg_do = {1'h0, spi_rd_late, spi_mode, spi_ce_delay, spi_clk_div};
         4'hf: dbg_do = ttlc_base_addr;
         default dbg_do = 16'h0;
         endcase
      end
      else if (dbg_a[7:4] == 4'h2 && dbg_rd == 1'b1)
      begin
         case (dbg_a[3:0])
         4'h0: dbg_do = debug_rdata;
         4'h1: dbg_do = debug_rdata;
         4'h2: dbg_do = debug_rdata;
         default dbg_do = 16'h0;
         endcase
      end
      else if (dbg_a[7:4] == 4'h4 && dbg_rd == 1'b1)
      begin
         case (dbg_a[3:0])
         4'h0: dbg_do = {9'h0, ttlc_data_out, ttlc_data_in, ttlc_result_reg, ttlc_shiftclk, ttlc_reset, ttlc_step, ttlc_run};
         4'h1: dbg_do = {2'h0, ttlc_pc};
         4'h8: dbg_do = {1'h0, ttlc_brk_addr0};
         4'h9: dbg_do = {1'h0, ttlc_brk_addr1};
         4'hA: dbg_do = {1'h0, ttlc_brk_addr2};
         default dbg_do = 16'h0;
         endcase
      end
`ifdef DONT_COMPILE
      else if (dbg_a[7:4] == 4'h5 && dbg_rd == 1'b1)
      begin
         case (dbg_a[3:0])
         4'h0: dbg_do = ttlc_outputs[15:0];
         4'h1: dbg_do = ttlc_outputs[31:16];
         4'h2: dbg_do = ttlc_outputs[47:32];
         4'h3: dbg_do = ttlc_outputs[63:48];
         4'h4: dbg_do = ttlc_inputs[15:0];
         4'h5: dbg_do = ttlc_inputs[31:16];
         4'h6: dbg_do = ttlc_inputs[47:32];
         4'h7: dbg_do = ttlc_inputs[63:48];
         4'h8: dbg_do = ttlc_storage[15:0];
         4'h9: dbg_do = ttlc_storage[31:16];
         default dbg_do = 16'h0;
         endcase
      end
`endif
   end

   assign ttlc_brk  = ttlc_brk_addr0 == {1'b1, ttlc_pc} ||
                      ttlc_brk_addr1 == {1'b1, ttlc_pc} ||
                      ttlc_brk_addr2 == {1'b1, ttlc_pc};
   assign ttlc_halt = !(ttlc_run | ttlc_step) | (ttlc_brk & !ttlc_skip & !ttlc_step);

endmodule

