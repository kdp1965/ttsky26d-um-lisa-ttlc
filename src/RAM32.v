/// sta-blackbox

`default_nettype wire

module RAM32 (
`ifdef USE_POWER_PINS
    input VPWR,
    input VGND,
`endif
    input CLK,
    input [3:0] WE0,
    input EN0,
    input [4:0] A0,
    input [31:0] Di0,
    output reg [31:0] Do0
);
  reg [31:0] RAM[31:0];

`ifndef SYNTHESIS
  // Simulation only (2026-11-15): the array starts at zero, as the hardened
  // macro's latches never do.  Under four-state simulation a byte read
  // before it is written is X, and sdcc's 16-bit values travel through IX
  // by a three-byte `ldxx n(sp)` whose third byte the code never wrote: the
  // X in IX[22:16] then reaches the top's d_addr_c == d_addr_r compare
  // while a load is acknowledged and stalls the core (misc40's HSC handler
  // under icarus, RTL and gate level alike).  Silicon has a random byte
  // there and the compare resolves in a cycle.
  integer i;
  initial for (i = 0; i < 32; i = i + 1) RAM[i] = 32'h0;
`endif

  // Read during write of the same word: the DFFRAM macro's storage is
  // latches written in the clock after the inputs are sampled and read
  // through a combinational mux, so Do0 shows the byte just written
  // (write-first).  The TT07 read-modify-write cache bug depended on it.
  always @(posedge CLK)
    if (EN0) begin
      Do0[7:0]   <= WE0[0] ? Di0[7:0]   : RAM[A0][7:0];
      Do0[15:8]  <= WE0[1] ? Di0[15:8]  : RAM[A0][15:8];
      Do0[23:16] <= WE0[2] ? Di0[23:16] : RAM[A0][23:16];
      Do0[31:24] <= WE0[3] ? Di0[31:24] : RAM[A0][31:24];
      if (WE0[0]) RAM[A0][7:0] <= Di0[7:0];
      if (WE0[1]) RAM[A0][15:8] <= Di0[15:8];
      if (WE0[2]) RAM[A0][23:16] <= Di0[23:16];
      if (WE0[3]) RAM[A0][31:24] <= Di0[31:24];
    end else begin
      Do0 <= 32'b0;
    end

endmodule
