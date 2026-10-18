// CRC-32 (IEEE 802.3) advanced by one byte, the reflected form: start at
// 32'hffffffff, feed the frame's bytes in order, send ~crc low byte first
// as the FCS; fed a frame including its FCS the register ends at
// 32'hdebb20e3.  zlib.crc32 computes the same thing on the host.
module eth_crc32_byte
(
   input  wire [31:0]   crc,
   input  wire [7:0]    data,
   output wire [31:0]   next
);
   function [31:0] step;
      input [31:0] c;
      input [7:0]  d;
      integer      i;
      reg   [31:0] r;
      begin
         r = c ^ {24'h0, d};
         for (i = 0; i < 8; i = i + 1)
            r = (r >> 1) ^ (r[0] ? 32'hedb88320 : 32'h0);
         step = r;
      end
   endfunction

   assign next = step(crc, data);
endmodule
