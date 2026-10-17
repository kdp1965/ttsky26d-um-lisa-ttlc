// The Arty's 100 MHz oscillator to the project clock through an MMCM:
// VCO 1000 MHz, CLKOUT_DIVIDE 20 = 50 MHz (the demo board SDK's default),
// 15 = 66.67 MHz (the chip's ceiling, see the TT07 notes), 10 = 100 MHz.
// Under Verilator (lint, simulation) a divide-by-two stands in.
module lisa_arty_clk
#(
   parameter CLKOUT_DIVIDE = 20
)
(
   input  wire    clk_in,
   output wire    clk_out,
   output wire    locked
);

`ifdef VERILATOR
   reg            q = 1'b0;
   always @(posedge clk_in)
      q <= ~q;
   assign clk_out = q;
   assign locked  = 1'b1;
`else
   wire           clkfb;
   wire           clk_mmcm;

   MMCME2_BASE
   #(
      .BANDWIDTH          ( "OPTIMIZED"   ),
      .CLKIN1_PERIOD      ( 10.0          ),
      .DIVCLK_DIVIDE      ( 1             ),
      .CLKFBOUT_MULT_F    ( 10.0          ),
      .CLKFBOUT_PHASE     ( 0.0           ),
      .CLKOUT0_DIVIDE_F   ( CLKOUT_DIVIDE * 1.0 ),
      .CLKOUT0_DUTY_CYCLE ( 0.5           ),
      .CLKOUT0_PHASE      ( 0.0           ),
      .REF_JITTER1        ( 0.01          ),
      .STARTUP_WAIT       ( "FALSE"       )
   )
   mmcm
   (
      .CLKIN1     ( clk_in   ),
      .CLKFBIN    ( clkfb    ),
      .CLKFBOUT   ( clkfb    ),
      .CLKFBOUTB  (          ),
      .CLKOUT0    ( clk_mmcm ),
      .CLKOUT0B   (          ),
      .CLKOUT1    (          ),
      .CLKOUT1B   (          ),
      .CLKOUT2    (          ),
      .CLKOUT2B   (          ),
      .CLKOUT3    (          ),
      .CLKOUT3B   (          ),
      .CLKOUT4    (          ),
      .CLKOUT5    (          ),
      .CLKOUT6    (          ),
      .LOCKED     ( locked   ),
      .RST        ( 1'b0     ),
      .PWRDWN     ( 1'b0     )
   );

   BUFG bufg
   (
      .I          ( clk_mmcm ),
      .O          ( clk_out  )
   );
`endif

endmodule
