// The TTLC I/O over UDP: the 48 inputs the FPGA's 74HC165 chain model
// loads come from the host, the 48 outputs its 74HC595 chain model holds
// go back.  A datagram to UDP_PORT is a command byte and, for I, six
// bytes:
//
//    I b0..b5   set the 48 inputs (b0 = inputs 7..0, little-endian)
//    R          read
//    S          subscribe: send an E datagram to this sender whenever the
//               outputs change (at most one every EVENT_GAP_US)
//    U          unsubscribe
//
// Every datagram is answered with the 20-byte status below, type S; an
// event is the same with type E.  Little-endian throughout.
//
//    0      'S' or 'E'
//    1      flags: bit 0 subscribed, bit 1 the Pmod chains are selected
//           (the board's SW3), bits 7:4 this format's version, 1
//    2..5   microseconds since reset
//    6..11  the 48 outputs
//    12..17 the 48 inputs
//    18..19 events sent
module ttlc_eth_app
#(
   parameter TICKS_PER_US = 40,
   parameter EVENT_GAP_US = 100
)
(
   input  wire          clk,
   input  wire          rst_n,

   input  wire          udp_rx_strobe,
   input  wire [7:0]    udp_rx_byte,
   input  wire          udp_rx_first,
   input  wire          udp_rx_last,
   input  wire [47:0]   udp_rx_src_mac,
   input  wire [31:0]   udp_rx_src_ip,
   input  wire [15:0]   udp_rx_src_port,

   output reg           udp_tx_start,
   output wire [10:0]   udp_tx_len,
   input  wire [10:0]   udp_tx_idx,
   output wire [7:0]    udp_tx_byte,
   output reg  [47:0]   udp_tx_dst_mac,
   output reg  [31:0]   udp_tx_dst_ip,
   output reg  [15:0]   udp_tx_dst_port,
   input  wire          udp_tx_ready,

   output reg  [47:0]   ttlc_in,        // what the input chains load
   input  wire [47:0]   ttlc_out,       // what the output chains hold
   input  wire          pmod_sel        // the real Pmod chains are in use
);

   localparam [3:0]  VERSION = 4'd1;

   // microseconds
   reg  [7:0]     us_div;
   reg  [31:0]    us;
   wire           us_tick = us_div == TICKS_PER_US - 1;

   always @(posedge clk or negedge rst_n)
   begin
      if (!rst_n)
      begin
         us_div <= 8'h0;
         us     <= 32'h0;
      end
      else
      begin
         us_div <= us_tick ? 8'h0 : us_div + 1'b1;
         if (us_tick)
            us <= us + 1'b1;
      end
   end

   // the command
   reg  [7:0]     cmd;
   reg  [2:0]     argn;
   reg  [47:0]    arg;
   reg            reply;           // a status datagram is owed to rep_*
   reg  [47:0]    rep_mac;
   reg  [31:0]    rep_ip;
   reg  [15:0]    rep_port;
   reg            subscribed;
   reg  [47:0]    sub_mac;
   reg  [31:0]    sub_ip;
   reg  [15:0]    sub_port;
   reg  [47:0]    last_out;        // the outputs as last reported
   reg  [15:0]    events;
   reg  [15:0]    gap;             // microseconds until the next event may go
   reg  [159:0]   tx_vec;

   wire [7:0]     cmd_now = udp_rx_first ? udp_rx_byte : cmd;
   wire [7:0]     flags   = {VERSION, 2'b00, pmod_sel, subscribed};
   wire           change  = subscribed && ttlc_out != last_out && gap == 16'h0;

   assign udp_tx_len  = 11'd20;
   assign udp_tx_byte = udp_tx_idx < 11'd20 ? tx_vec[udp_tx_idx[4:0] * 8 +: 8] : 8'h00;

   always @(posedge clk or negedge rst_n)
   begin
      if (!rst_n)
      begin
         cmd          <= 8'h0;
         argn         <= 3'h0;
         arg          <= 48'h0;
         reply        <= 1'b0;
         subscribed   <= 1'b0;
         ttlc_in      <= 48'h0;
         last_out     <= 48'h0;
         events       <= 16'h0;
         gap          <= 16'h0;
         udp_tx_start <= 1'b0;
         tx_vec       <= 160'h0;
      end
      else
      begin
         udp_tx_start <= 1'b0;
         if (us_tick && gap != 16'h0)
            gap <= gap - 1'b1;

         if (udp_rx_strobe)
         begin
            if (udp_rx_first)
            begin
               cmd  <= udp_rx_byte;
               argn <= 3'h0;
            end
            else if (argn != 3'd6)
            begin
               arg  <= {udp_rx_byte, arg[47:8]};
               argn <= argn + 1'b1;
               if (argn == 3'd5 && cmd == 8'h49)                // I: this byte completes the six
                  ttlc_in <= {udp_rx_byte, arg[47:8]};
            end
            if (udp_rx_last)
            begin
               case (cmd_now)
                  8'h53:                                        // S
                  begin
                     subscribed <= 1'b1;
                     sub_mac    <= udp_rx_src_mac;
                     sub_ip     <= udp_rx_src_ip;
                     sub_port   <= udp_rx_src_port;
                  end
                  8'h55: subscribed <= 1'b0;                   // U
                  default: ;
               endcase
               reply    <= 1'b1;
               rep_mac  <= udp_rx_src_mac;
               rep_ip   <= udp_rx_src_ip;
               rep_port <= udp_rx_src_port;
            end
         end

         if (udp_tx_ready && (reply || change))
         begin
            udp_tx_start    <= 1'b1;
            udp_tx_dst_mac  <= reply ? rep_mac  : sub_mac;
            udp_tx_dst_ip   <= reply ? rep_ip   : sub_ip;
            udp_tx_dst_port <= reply ? rep_port : sub_port;
            tx_vec          <= {reply ? events : events + 1'b1, ttlc_in, ttlc_out, us, flags, reply ? 8'h53 : 8'h45};
            last_out        <= ttlc_out;
            if (reply)
               reply <= 1'b0;
            else
            begin
               events <= events + 1'b1;
               gap    <= EVENT_GAP_US;
            end
         end
      end
   end

endmodule
