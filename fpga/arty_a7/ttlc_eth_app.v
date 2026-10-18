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
//    X          take the QSPI Pmod's flash bus: the chip is held in reset
//               and the bridge drives CS, SCLK and MOSI (uio[0], [3], [1])
//               and reads MISO (uio[2]); uio[7:4] (HOLD#, WP#, the PSRAM
//               selects) are held high.  Released by Y, or 5 s after the
//               last X or T (the host died)
//    Y          give the bus back to the chip (which restarts)
//    T b0..bn   one SPI transaction while the bus is held: CS low, the
//               bytes out on MOSI (mode 0, clk/4), CS high; answered with
//               'T' and the n bytes read on MISO.  n up to 1024: a page
//               program (02 + address + 256 bytes) or a 1020-byte read
//               (03 + address + 1020 dummies) is one datagram, so a
//               program image takes milliseconds instead of the debug
//               UART's minutes (2026-10-18, Ken's request)
//
// Every other datagram is answered with the 20-byte status below, type
// S; an event is the same with type E.  Little-endian throughout.
//
//    0      'S' or 'E'
//    1      flags: bit 0 subscribed, bit 1 the Pmod chains are selected
//           (the board's SW3), bit 2 the flash bus is held, bits 7:4
//           this format's version, 2
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
   input  wire          pmod_sel,       // the real Pmod chains are in use

   // the flash bus while it is held (spi_own)
   output reg           spi_own,
   output reg           spi_cs_n,
   output reg           spi_sclk,
   output reg           spi_mosi,
   input  wire          spi_miso
);

   localparam [3:0]  VERSION = 4'd2;
   localparam        SPI_HALF = 2;     // clocks per half SCLK period: clk/4
   localparam [22:0] OWN_TIMEOUT_US = 23'd5000000;

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

   // the SPI transaction: the bytes to send, the bytes read, the engine
   reg  [7:0]     tbuf [0:1023];
   reg  [7:0]     rbuf [0:1023];
   reg  [10:0]    tcnt;            // bytes of the T command stored
   reg  [10:0]    tlen;            // bytes of the transaction
   reg            t_go;            // a transaction to run
   reg            t_busy;
   reg            t_done;          // the reply is owed
   reg  [10:0]    t_idx;
   reg  [2:0]     t_bit;
   reg  [1:0]     t_div;
   reg  [7:0]     t_sh;            // the byte going out
   reg  [7:0]     t_in;            // the byte coming in
   reg  [1:0]     t_state;
   reg            reply_t;         // the reply owed is a T (else a status)
   reg  [22:0]    own_us;          // microseconds since the last X or T
   localparam [1:0] T_IDLE = 2'd0, T_LOW = 2'd1, T_HIGH = 2'd2, T_END = 2'd3;

   wire [7:0]     cmd_now = udp_rx_first ? udp_rx_byte : cmd;
   wire [7:0]     flags   = {VERSION, 1'b0, spi_own, pmod_sel, subscribed};
   wire           change  = subscribed && ttlc_out != last_out && gap == 16'h0;
   wire [10:0]    t_rd    = udp_tx_idx - 11'd1;

   assign udp_tx_len  = reply_t ? tlen + 11'd1 : 11'd20;
   assign udp_tx_byte = reply_t ? (udp_tx_idx == 11'd0 ? 8'h54 : rbuf[t_rd[9:0]]) :
                        udp_tx_idx < 11'd20 ? tx_vec[udp_tx_idx[4:0] * 8 +: 8] : 8'h00;

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
         tcnt         <= 11'h0;
         tlen         <= 11'h0;
         t_go         <= 1'b0;
         reply_t      <= 1'b0;
         spi_own      <= 1'b0;
         own_us       <= 23'h0;
      end
      else
      begin
         udp_tx_start <= 1'b0;
         t_go         <= 1'b0;
         if (us_tick && gap != 16'h0)
            gap <= gap - 1'b1;
         // the bus is given back when the host goes quiet
         if (us_tick && spi_own && own_us != OWN_TIMEOUT_US)
            own_us <= own_us + 1'b1;
         if (spi_own && own_us == OWN_TIMEOUT_US && !t_busy)
            spi_own <= 1'b0;

         if (udp_rx_strobe)
         begin
            if (udp_rx_first)
            begin
               cmd  <= udp_rx_byte;
               argn <= 3'h0;
               tcnt <= 11'h0;
            end
            else
            begin
               if (argn != 3'd6)
               begin
                  arg  <= {udp_rx_byte, arg[47:8]};
                  argn <= argn + 1'b1;
                  if (argn == 3'd5 && cmd == 8'h49)             // I: this byte completes the six
                     ttlc_in <= {udp_rx_byte, arg[47:8]};
               end
               if (cmd == 8'h54 && tcnt != 11'd1024)           // T: the bytes to send
               begin
                  tbuf[tcnt[9:0]] <= udp_rx_byte;
                  tcnt <= tcnt + 1'b1;
               end
            end
            if (udp_rx_last)
            begin
               rep_mac  <= udp_rx_src_mac;
               rep_ip   <= udp_rx_src_ip;
               rep_port <= udp_rx_src_port;
               reply    <= 1'b1;                                // a status, unless a T runs
               case (cmd_now)
                  8'h53:                                        // S
                  begin
                     subscribed <= 1'b1;
                     sub_mac    <= udp_rx_src_mac;
                     sub_ip     <= udp_rx_src_ip;
                     sub_port   <= udp_rx_src_port;
                  end
                  8'h55: subscribed <= 1'b0;                   // U
                  8'h58:                                        // X: take the bus
                  begin
                     spi_own <= 1'b1;
                     own_us  <= 23'h0;
                  end
                  8'h59: if (!t_busy) spi_own <= 1'b0;          // Y: give it back
                  8'h54:                                        // T
                     if (spi_own && !t_busy && !udp_rx_first)
                     begin
                        tlen   <= tcnt + 1'b1;                  // this byte included
                        t_go   <= 1'b1;
                        own_us <= 23'h0;
                        reply  <= 1'b0;                         // the T reply comes when it is done
                     end
                  default: ;
               endcase
            end
         end

         if (udp_tx_ready && t_done)
         begin
            udp_tx_start    <= 1'b1;
            reply_t         <= 1'b1;
            udp_tx_dst_mac  <= rep_mac;
            udp_tx_dst_ip   <= rep_ip;
            udp_tx_dst_port <= rep_port;
         end
         else if (udp_tx_ready && (reply || change))
         begin
            udp_tx_start    <= 1'b1;
            reply_t         <= 1'b0;
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

   // The SPI engine: mode 0 at clk / (2 x SPI_HALF).  MOSI changes while
   // SCLK is low and the flash samples it on the rise; MISO is sampled on
   // the rise too (the flash drives it after the fall).
   always @(posedge clk or negedge rst_n)
   begin
      if (!rst_n)
      begin
         t_state  <= T_IDLE;
         t_busy   <= 1'b0;
         spi_cs_n <= 1'b1;
         spi_sclk <= 1'b0;
         spi_mosi <= 1'b0;
         t_idx    <= 11'h0;
         t_bit    <= 3'h0;
         t_div    <= 2'h0;
      end
      else
      begin
         case (t_state)
            T_IDLE:
            begin
               spi_sclk <= 1'b0;
               if (t_go)
               begin
                  t_busy   <= 1'b1;
                  spi_cs_n <= 1'b0;
                  t_idx    <= 11'h0;
                  t_bit    <= 3'd7;
                  t_div    <= 2'h0;
                  t_sh     <= tbuf[0];
                  t_state  <= T_LOW;
               end
            end

            T_LOW:                                   // SCLK low: the bit on MOSI
            begin
               spi_mosi <= t_sh[7];
               t_div    <= t_div + 1'b1;
               if (t_div == SPI_HALF - 1)
               begin
                  t_div    <= 2'h0;
                  spi_sclk <= 1'b1;
                  t_in     <= {t_in[6:0], spi_miso};
                  t_state  <= T_HIGH;
               end
            end

            T_HIGH:
            begin
               t_div <= t_div + 1'b1;
               if (t_div == SPI_HALF - 1)
               begin
                  t_div    <= 2'h0;
                  spi_sclk <= 1'b0;
                  t_sh     <= {t_sh[6:0], 1'b0};
                  t_bit    <= t_bit - 1'b1;
                  t_state  <= T_LOW;
                  if (t_bit == 3'd0)
                  begin
                     rbuf[t_idx[9:0]] <= t_in;
                     t_idx <= t_idx + 1'b1;
                     t_bit <= 3'd7;
                     t_sh  <= tbuf[t_idx[9:0] + 10'd1];
                     if (t_idx + 1'b1 == tlen)
                        t_state <= T_END;
                  end
               end
            end

            T_END:                                   // SCLK low a half period, then CS high
            begin
               t_div <= t_div + 1'b1;
               if (t_div == SPI_HALF - 1)
               begin
                  spi_cs_n <= 1'b1;
                  t_busy   <= 1'b0;
                  t_state  <= T_IDLE;
               end
            end
         endcase
      end
   end

   // the T reply once the transaction has ended
   always @(posedge clk or negedge rst_n)
   begin
      if (!rst_n)
         t_done <= 1'b0;
      else if (t_busy && t_state == T_END && t_div == SPI_HALF - 1)
         t_done <= 1'b1;
      else if (udp_tx_ready && t_done)
         t_done <= 1'b0;
   end

endmodule
