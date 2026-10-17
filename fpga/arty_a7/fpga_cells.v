// The sky130 cells debug_regs.v and lisa_dbg.v instantiate, for the FPGA.
//
// The chip keeps its static debug registers (base addresses, the output
// and I/O muxes, breakpoints) in dlrtp latches gated by the debug write
// strobe.  On the FPGA they are flops: latch2flop.py rewrites the two
// files so that each latch is an fpga_dlrtp clocked by the module's clk,
// which captures D at the clock edges while GATE is high - the strobe is
// a whole-cycle signal with dbg_di stable, so the value is the one the
// latch would hold.
module fpga_dlrtp
(
   input  wire    CLK,
   input  wire    RESET_B,
   input  wire    GATE,
   input  wire    D,
   output reg     Q
);
   always @(posedge CLK or negedge RESET_B)
   begin
      if (!RESET_B)
         Q <= 1'b0;
      else if (GATE)
         Q <= D;
   end
endmodule

module sky130_fd_sc_hd__and2_4
(
   input  wire    A,
   input  wire    B,
   output wire    X
);
   assign X = A & B;
endmodule
