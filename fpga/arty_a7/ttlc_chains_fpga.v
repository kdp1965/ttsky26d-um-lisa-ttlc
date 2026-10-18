// The TTLC Pmod's three 74HC595 and three 74HC165 chains (16 stages each)
// inside the FPGA, on the system clock: test/tb.v's ttlc_chains made
// synchronous.  The chip's scan (shift_reg_io.v) drives the shift clock at
// clk/4 or slower and holds its data from one shift clock edge to the
// next, so sampling the pins every clock and acting on the registered
// edges sees what the real chips see.
//
// 595: the serial data shifts in on the rising edge of sclk, the first bit
// in ends at stage 15; the 48 outputs latch on the rising edge of latch.
// 165: the inputs load while latch (/PL) is low, else they shift on the
// rising edge of sclk; the serial output is stage 15.
module ttlc_chains_fpga
(
   input  wire          clk,
   input  wire          rst_n,
   input  wire          sclk,
   input  wire          latch,
   input  wire [2:0]    dout,           // into the 595 chains
   output wire [2:0]    din,            // out of the 165 chains
   input  wire [47:0]   inputs,
   output reg  [47:0]   outputs
);

   reg  [47:0]    sr595;
   reg  [47:0]    sr165;
   reg            sclk_r;
   reg            latch_r;
   wire           sclk_rise  = sclk & ~sclk_r;
   wire           latch_rise = latch & ~latch_r;

   assign din = {sr165[47], sr165[31], sr165[15]};

   always @(posedge clk or negedge rst_n)
   begin
      if (!rst_n)
      begin
         sr595   <= 48'h0;
         sr165   <= 48'h0;
         outputs <= 48'h0;
         sclk_r  <= 1'b0;
         latch_r <= 1'b1;
      end
      else
      begin
         sclk_r  <= sclk;
         latch_r <= latch;
         if (sclk_rise)
            sr595 <= {sr595[46:32], dout[2], sr595[30:16], dout[1], sr595[14:0], dout[0]};
         if (latch_rise)
            outputs <= sr595;
         if (!latch)
            sr165 <= inputs;
         else if (sclk_rise)
            sr165 <= {sr165[46:32], 1'b0, sr165[30:16], 1'b0, sr165[14:0], 1'b0};
      end
   end

endmodule
