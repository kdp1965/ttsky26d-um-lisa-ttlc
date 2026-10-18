// A frame-at-a-time Ethernet MAC on a MII PHY (the Arty A7's DP83848J):
// received frames in two 2 KB buffers, one frame to send in another,
// each buffer handed between the PHY's clock and the system clock by a
// four-phase handshake, so everything above this module runs on the
// system clock.
//
// Receive (mii_rx_clk): the nibbles after the SFD are assembled into bytes
// and written to one of two buffers, used in turn, while the CRC runs
// over them; when RX_DV drops a frame of 64 to 1536 bytes with a good FCS
// and no RX_ER is offered to the system side (rx_valid, rx_len without
// the FCS, bytes through rx_addr / rx_data a clock later) until rx_done,
// after which rx_valid shows the next frame, if one is waiting, two
// clocks later.  A frame that arrives while its buffer is still held is
// dropped - the host retries.
//
// Transmit (mii_tx_clk): the system side writes a frame without its FCS
// (tx_we / tx_addr / tx_data), then pulses tx_start with tx_len; the
// frame goes out with its preamble, padded to 60 bytes, the FCS appended,
// followed by the inter-frame gap; tx_busy until then.
//
// Full duplex only: no carrier sense, no collision handling.
module eth_mii_mac
(
   input  wire          clk,            // system clock
   input  wire          rst_n,

   // MII
   input  wire          mii_rx_clk,
   input  wire          mii_rx_dv,
   input  wire          mii_rx_er,
   input  wire [3:0]    mii_rxd,
   input  wire          mii_tx_clk,
   output reg           mii_tx_en,
   output reg  [3:0]    mii_txd,

   // the received frame
   output wire          rx_valid,
   output wire [10:0]   rx_len,         // bytes, FCS excluded
   input  wire [10:0]   rx_addr,
   output reg  [7:0]    rx_data,        // the byte at rx_addr, one clock later
   input  wire          rx_done,        // pulse: release the buffer

   // the frame to send
   input  wire          tx_we,
   input  wire [10:0]   tx_addr,
   input  wire [7:0]    tx_data,
   input  wire          tx_start,       // pulse, with tx_len
   input  wire [10:0]   tx_len,         // bytes, FCS excluded
   output wire          tx_busy,

   // activity pulses on the system clock
   output reg           rx_act,         // any frame ended (good or not)
   output wire          tx_act          // a frame was started
);

   // ====================================================================
   // Receive, mii_rx_clk domain: two buffers, frames alternate between
   // them, so a frame may follow another by the inter-frame gap while the
   // first is still being parsed (the parse and release take ~2 us)
   // ====================================================================
   (* ram_style = "block" *) reg [7:0] rx_buf [0:4095];

   // reset and the handshake acknowledges, synchronized
   reg  [1:0]     r_rst_s   = 2'b11;
   reg  [1:0]     r_ack_s0  = 2'b00;
   reg  [1:0]     r_ack_s1  = 2'b00;
   reg  [3:0]     r_rxd     = 4'h0;    // the pins, registered
   reg            r_dv      = 1'b0;
   reg            r_er      = 1'b0;
   reg            r_inframe = 1'b0;    // after the SFD
   reg            r_hi      = 1'b0;    // the high nibble is next
   reg  [3:0]     r_lo      = 4'h0;    // the low nibble (the previous one in the preamble)
   reg  [10:0]    r_cnt     = 11'h0;   // bytes received
   reg            r_err     = 1'b0;
   reg            r_drop    = 1'b0;    // this frame has nowhere to go
   reg            r_sel     = 1'b0;    // the buffer the next frame goes to
   reg  [31:0]    r_crc     = 32'hffffffff;
   reg  [1:0]     r_req     = 2'b00;   // a frame is in buffer k for the system side
   reg  [10:0]    r_len0    = 11'h0;
   reg  [10:0]    r_len1    = 11'h0;
   reg            r_tog     = 1'b0;    // toggles at every frame end
   reg            r_we      = 1'b0;
   reg  [11:0]    r_wa      = 12'h0;
   reg  [7:0]     r_wd      = 8'h0;

   wire           r_rst  = r_rst_s[1];
   wire [1:0]     r_busy = r_req | {r_ack_s1[1], r_ack_s0[1]};   // the system side still owns buffer k
   wire [7:0]     r_byte = {r_rxd, r_lo};
   wire [31:0]    r_crc_next;

   eth_crc32_byte rx_crc ( .crc(r_crc), .data(r_byte), .next(r_crc_next) );

   always @(posedge mii_rx_clk)
   begin
      r_rst_s  <= {r_rst_s[0], ~rst_n};
      r_ack_s0 <= {r_ack_s0[0], s_ack[0]};
      r_ack_s1 <= {r_ack_s1[0], s_ack[1]};
      r_rxd    <= mii_rxd;
      r_dv     <= mii_rx_dv;
      r_er     <= mii_rx_er;
      r_we     <= 1'b0;
      if (r_we)
         rx_buf[r_wa] <= r_wd;

      if (r_rst)
      begin
         r_req     <= 2'b00;
         r_sel     <= 1'b0;
         r_inframe <= 1'b0;
         r_hi      <= 1'b0;
         r_cnt     <= 11'h0;
         r_err     <= 1'b0;
         r_crc     <= 32'hffffffff;
      end
      else
      begin
         if (r_req[0] && r_ack_s0[1])
            r_req[0] <= 1'b0;                           // taken
         if (r_req[1] && r_ack_s1[1])
            r_req[1] <= 1'b0;

         if (!r_dv)
         begin
            if (r_inframe)
            begin
               r_tog <= ~r_tog;
               if (!r_drop && !r_err && !r_hi && r_cnt >= 11'd64 && r_cnt <= 11'd1536 &&
                   r_crc == 32'hdebb20e3)
               begin
                  r_req[r_sel] <= 1'b1;
                  if (r_sel)
                     r_len1 <= r_cnt - 11'd4;
                  else
                     r_len0 <= r_cnt - 11'd4;
                  r_sel <= ~r_sel;
               end
            end
            r_inframe <= 1'b0;
            r_hi      <= 1'b0;
            r_lo      <= 4'h0;
            r_cnt     <= 11'h0;
            r_err     <= 1'b0;
            r_crc     <= 32'hffffffff;
         end
         else if (!r_inframe)
         begin
            // the preamble: nibbles of 5 until the SFD's D
            r_lo <= r_rxd;
            if (r_rxd == 4'hd && r_lo == 4'h5)
            begin
               r_inframe <= 1'b1;
               r_drop    <= r_busy[r_sel];
            end
         end
         else
         begin
            if (r_er)
               r_err <= 1'b1;
            if (!r_hi)
            begin
               r_lo <= r_rxd;
               r_hi <= 1'b1;
            end
            else
            begin
               r_hi  <= 1'b0;
               r_crc <= r_crc_next;
               if (r_cnt != 11'h7ff)
                  r_cnt <= r_cnt + 1'b1;
               if (!r_drop && r_cnt < 11'd1536)
               begin
                  r_we <= 1'b1;
                  r_wa <= {r_sel, r_cnt};
                  r_wd <= r_byte;
               end
            end
         end
      end
   end

   // ====================================================================
   // Receive, system clock side: the buffers are taken in turn
   // ====================================================================
   reg  [1:0]     s_req_s0, s_req_s1;
   reg  [1:0]     s_ack;
   reg            s_next;          // the buffer the next frame is read from
   reg  [1:0]     s_tog_s;
   reg            s_tog_d;

   wire [1:0]     s_req = {s_req_s1[1], s_req_s0[1]};

   always @(posedge clk)
   begin
      s_req_s0 <= {s_req_s0[0], r_req[0]};
      s_req_s1 <= {s_req_s1[0], r_req[1]};
      s_tog_s  <= {s_tog_s[0], r_tog};
      s_tog_d  <= s_tog_s[1];
      rx_act   <= s_tog_s[1] ^ s_tog_d;
      rx_data  <= rx_buf[{s_next, rx_addr}];
   end

   always @(posedge clk or negedge rst_n)
   begin
      if (!rst_n)
      begin
         s_ack  <= 2'b00;
         s_next <= 1'b0;
      end
      else
      begin
         if (rx_done)
         begin
            s_ack[s_next] <= 1'b1;
            s_next        <= ~s_next;
         end
         if (s_ack[0] && !s_req[0])
            s_ack[0] <= 1'b0;
         if (s_ack[1] && !s_req[1])
            s_ack[1] <= 1'b0;
      end
   end

   assign rx_valid = s_req[s_next] & ~s_ack[s_next];
   assign rx_len   = s_next ? r_len1 : r_len0;      // stable before r_req rises

   // ====================================================================
   // Transmit, system clock side
   // ====================================================================
   (* ram_style = "block" *) reg [7:0] tx_buf [0:2047];

   reg            s_treq;
   reg  [10:0]    s_tlen;
   reg  [1:0]     s_tack_s;

   always @(posedge clk)
   begin
      if (tx_we)
         tx_buf[tx_addr] <= tx_data;
      s_tack_s <= {s_tack_s[0], t_ack};
   end

   always @(posedge clk or negedge rst_n)
   begin
      if (!rst_n)
      begin
         s_treq <= 1'b0;
         s_tlen <= 11'h0;
      end
      else if (tx_start)
      begin
         s_treq <= 1'b1;
         s_tlen <= tx_len;
      end
      else if (s_tack_s[1])
         s_treq <= 1'b0;
   end

   assign tx_busy = s_treq | s_tack_s[1];
   assign tx_act  = tx_start;

   // ====================================================================
   // Transmit, mii_tx_clk domain
   // ====================================================================
   localparam [2:0] T_IDLE = 3'd0, T_PRE = 3'd1, T_DATA = 3'd2, T_FCS = 3'd3, T_IFG = 3'd4, T_ACK = 3'd5;

   reg  [1:0]     t_rst_s  = 2'b11;
   reg  [1:0]     t_req_s  = 2'b00;
   reg            t_ack    = 1'b0;
   reg  [2:0]     t_state  = T_IDLE;
   reg  [4:0]     t_nib    = 5'h0;     // nibbles of the preamble / FCS, IFG clocks
   reg            t_hi     = 1'b0;
   reg  [10:0]    t_cnt    = 11'h0;    // the next byte to fetch
   reg  [10:0]    t_sent   = 11'h0;    // bytes sent so far
   reg  [10:0]    t_len    = 11'h0;    // bytes to send, padded
   reg  [7:0]     t_rd     = 8'h0;
   reg  [7:0]     t_byte   = 8'h0;
   reg  [31:0]    t_crc    = 32'hffffffff;
   wire [31:0]    t_crc_next;
   wire [31:0]    t_fcs    = ~t_crc;

   eth_crc32_byte tx_crc ( .crc(t_crc), .data(t_byte), .next(t_crc_next) );

   initial
   begin
      mii_tx_en = 1'b0;
      mii_txd   = 4'h0;
   end

   always @(posedge mii_tx_clk)
   begin
      t_rst_s <= {t_rst_s[0], ~rst_n};
      t_req_s <= {t_req_s[0], s_treq};
      t_rd    <= tx_buf[t_cnt];

      if (t_rst_s[1])
      begin
         t_state   <= T_IDLE;
         t_ack     <= 1'b0;
         mii_tx_en <= 1'b0;
      end
      else
      case (t_state)
         T_IDLE:
         begin
            mii_tx_en <= 1'b0;
            t_cnt     <= 11'h0;
            t_nib     <= 5'h0;
            t_hi      <= 1'b0;
            t_sent    <= 11'h0;
            t_crc     <= 32'hffffffff;
            if (t_req_s[1])
            begin
               t_len   <= s_tlen < 11'd60 ? 11'd60 : s_tlen;
               t_state <= T_PRE;
            end
         end

         T_PRE:                                      // 7 x 55, D5: 15 nibbles of 5, one D
         begin
            mii_tx_en <= 1'b1;
            mii_txd   <= t_nib == 5'd15 ? 4'hd : 4'h5;
            t_nib     <= t_nib + 1'b1;
            if (t_nib == 5'd15)
            begin
               t_byte  <= t_cnt < s_tlen ? t_rd : 8'h0;  // byte 0 (t_rd has had the preamble to settle)
               t_cnt   <= 11'd1;
               t_state <= T_DATA;
            end
         end

         T_DATA:
         begin
            mii_txd <= t_hi ? t_byte[7:4] : t_byte[3:0];
            t_hi    <= ~t_hi;
            if (t_hi)
            begin
               t_crc  <= t_crc_next;
               t_sent <= t_sent + 1'b1;
               t_byte <= t_cnt < s_tlen ? t_rd : 8'h0;  // padding is zeros
               t_cnt  <= t_cnt + 1'b1;
               if (t_sent == t_len - 1'b1)
               begin
                  t_nib   <= 5'h0;
                  t_state <= T_FCS;
               end
            end
         end

         T_FCS:                                      // ~crc, low byte and low nibble first
         begin
            mii_txd <= t_fcs[t_nib[2:0] * 4 +: 4];
            t_nib   <= t_nib + 1'b1;
            if (t_nib == 5'd7)
            begin
               t_nib   <= 5'h0;
               t_state <= T_IFG;
            end
         end

         T_IFG:                                      // 96 bit times = 24 nibble clocks
         begin
            mii_tx_en <= 1'b0;
            mii_txd   <= 4'h0;
            t_nib     <= t_nib + 1'b1;
            if (t_nib == 5'd23)
            begin
               t_ack   <= 1'b1;
               t_state <= T_ACK;
            end
         end

         T_ACK:
         begin
            if (!t_req_s[1])
            begin
               t_ack   <= 1'b0;
               t_state <= T_IDLE;
            end
         end

         default:
            t_state <= T_IDLE;
      endcase
   end

endmodule
