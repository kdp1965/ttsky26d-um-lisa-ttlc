// The custom QSPI / I2C Pmod of io mux mode 3 (docs/info.md, "Special Mux
// Mode 3"), as board logic between the chip's uio and the Arty's JC (the
// Tiny Tapeout QSPI Pmod) and JD (I2C).
//
// In mode 3 (debug register 0x1c [7:6] = 3) the chip has no pins for steady
// chip selects: when they change it raises uio[0] for a clock and puts CE0 /
// CE1 on uio[1] / uio[2] for a clock and a half (RESPIN 39: half a clock and
// one before), and a latch on the custom Pmod (two 74LVC1G373 on Ken's)
// takes them - transparent while uio[0] is high.  The Pmod's
// series resistors keep that from reaching the parts' DQ0 / DQ1; here the
// chip's drive is simply not passed on during the strobe.  DQ2 / DQ3 are on
// uio[6] / uio[7] (0x1c [5:4] = 3), which leaves uio[4] / uio[5] for the
// I2C master (0x1c [1:0] = [3:2] = 2: 0x1c = 0x00fa).
//
// The parts are the Tiny Tapeout QSPI Pmod's, whose pin order is the
// chip's psram_mod one, so the signals are moved:
//
//   JC  pin  1 CS0 (flash)   the latched CE0
//            2 SD0           uio[1]   DQ0
//            3 SD1           uio[2]   DQ1
//            4 SCK           uio[3]
//            7 SD2           uio[6]   DQ2
//            8 SD3           uio[7]   DQ3
//            9 CS1 (PSRAM A) the latched CE1
//           10 CS2 (PSRAM B) high
//   JD  pin  1 SCL           uio[4]   open drain, pulled up
//            2 SDA           uio[5]   open drain, pulled up
//
// The latch is a real one (an LDPE, preset by reset to both deselected):
// the strobe is a compare that changes only at rising clock edges, so it
// does not glitch, and CE0 / CE1 are on uio[1] / uio[2] from the edge that
// raises it to the falling edge after the one that drops it - a clock of
// setup, half a clock of hold.
module m3_pmod
(
   input  wire          rst_n,
   input  wire [7:0]    uio_out,
   input  wire [7:0]    uio_oe,
   output wire [7:0]    uio_in,
   output wire [7:0]    jc_o,          // JC's drive ...
   output wire [7:0]    jc_oe,         // ... and its enables
   input  wire [7:0]    jc_i,
   output wire [1:0]    jd_low,        // JD: SCL / SDA pulled low (open drain) ...
   input  wire [1:0]    jd_i           // ... and what they are
);

   wire                 strobe = uio_out[0];
   reg   [1:0]          ce_l;

   always @*
      if (!rst_n)
         ce_l = 2'b11;
      else if (strobe)
         ce_l = uio_out[2:1];

   assign jc_o  = {1'b1, ce_l[1], uio_out[7], uio_out[6], uio_out[3], uio_out[2], uio_out[1], ce_l[0]};
   assign jc_oe = {1'b1, 1'b1, uio_oe[7], uio_oe[6], uio_oe[3], uio_oe[2] & ~strobe, uio_oe[1] & ~strobe, 1'b1};

   // open drain: the chip's I2C drives 0 or lets go
   assign jd_low = {uio_oe[5] && !uio_out[5], uio_oe[4] && !uio_out[4]};

   assign uio_in = {jc_i[5], jc_i[4], jd_i[1], jd_i[0], jc_i[3], jc_i[2], jc_i[1], 1'b0};

endmodule
