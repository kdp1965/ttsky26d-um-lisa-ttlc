// The Arty's 100 MHz oscillator to the project clock through an MMCM:
// VCO 1000 MHz, CLKOUT_DIVIDE 20 = 50 MHz (the demo board SDK's default),
// 15 = 66.67 MHz (the chip's ceiling, see the TT07 notes), 10 = 100 MHz.
// CLKOUT1 is the Ethernet PHY's 25 MHz reference.  Under Verilator (lint,
// simulation) a divide-by-two and a divide-by-four stand in.
module lisa_arty_clk
#(
   parameter CLKOUT_DIVIDE = 20
)
(
   input  wire    clk_in,
   output wire    clk_out,
   output wire    clk25,
   output wire    locked
);

`ifdef VERILATOR
   reg  [1:0]     q = 2'b00;
   always @(posedge clk_in)
      q <= q + 1'b1;
   assign clk_out = q[0];
   assign clk25   = q[1];
   assign locked  = 1'b1;
`else
   wire           clkfb;
   wire           clk_mmcm;
   wire           clk25_mmcm;

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
      .CLKOUT1_DIVIDE     ( 40            ),
      .CLKOUT1_DUTY_CYCLE ( 0.5           ),
      .CLKOUT1_PHASE      ( 0.0           ),
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
      .CLKOUT1    ( clk25_mmcm ),
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

   BUFG bufg25
   (
      .I          ( clk25_mmcm ),
      .O          ( clk25      )
   );
`endif

endmodule
