// A one-address IPv4 endpoint over eth_mii_mac: answers ARP requests for
// IP, echoes ICMP pings, delivers UDP datagrams sent to UDP_PORT as a byte
// stream and sends UDP datagrams from it.  Everything else is dropped.
//
// Received frames are parsed from the MAC's buffer a byte a clock and the
// buffer released at once (a ping holds it until the echo is built from
// it); a UDP payload for us streams out on udp_rx_strobe / udp_rx_byte
// (first / last flag the ends) with the sender in udp_rx_src_*.  A
// datagram to send is taken on udp_tx_start while udp_tx_ready: its bytes
// are fetched through udp_tx_idx / udp_tx_byte (combinational, the byte in
// the same clock) to udp_tx_dst_*, which must hold until udp_tx_ready
// returns.  The builder waits for the MAC's transmitter while the parser
// goes on with the next frame; replies the stack makes itself (ARP, ping)
// come first, and a second ARP request or ping while one is pending is
// dropped.  The IP header checksum is computed in a pass over the header
// before the frame is written; the UDP checksum is sent as zero (none)
// and not checked on receive.  No fragments, no options, no gateway: the
// hosts are on this subnet.
module eth_ipstack
#(
   parameter [47:0]  MAC      = 48'h02_4c_49_53_41_00,
   parameter [31:0]  IP       = {8'd192, 8'd168, 8'd1, 8'd200},
   parameter [15:0]  UDP_PORT = 16'd14500
)
(
   input  wire          clk,
   input  wire          rst_n,

   // the MAC's received frame
   input  wire          rx_valid,
   input  wire [10:0]   rx_len,
   output wire [10:0]   rx_addr,
   input  wire [7:0]    rx_data,
   output reg           rx_done,

   // the MAC's frame to send
   output reg           tx_we,
   output reg  [10:0]   tx_addr,
   output reg  [7:0]    tx_data,
   output reg           tx_start,
   output reg  [10:0]   tx_len,
   input  wire          tx_busy,

   // a UDP payload received on UDP_PORT
   output reg           udp_rx_strobe,
   output reg  [7:0]    udp_rx_byte,
   output reg           udp_rx_first,
   output reg           udp_rx_last,
   output reg  [47:0]   udp_rx_src_mac,
   output reg  [31:0]   udp_rx_src_ip,
   output reg  [15:0]   udp_rx_src_port,

   // a UDP payload to send from UDP_PORT
   input  wire          udp_tx_start,
   input  wire [10:0]   udp_tx_len,
   output reg  [10:0]   udp_tx_idx,
   input  wire [7:0]    udp_tx_byte,
   input  wire [47:0]   udp_tx_dst_mac,
   input  wire [31:0]   udp_tx_dst_ip,
   input  wire [15:0]   udp_tx_dst_port,
   output wire          udp_tx_ready,

   output reg           accepted        // pulse: a frame for us was handled
);

   localparam [1:0] P_IDLE = 2'd0, P_PARSE = 2'd1, P_DECIDE = 2'd2;
   localparam [2:0] B_IDLE = 3'd0, B_WAIT = 3'd1, B_SUM = 3'd2, B_FOLD = 3'd3, B_OUT = 3'd4, B_SEND = 3'd5;
   localparam [1:0] K_ARP = 2'd0, K_ICMP = 2'd1, K_UDP = 2'd2;

   reg  [1:0]     pstate;
   reg  [2:0]     bstate;
   reg  [1:0]     kind;
   reg  [10:0]    p_addr;           // the parser's address in the received frame
   reg  [10:0]    b_addr;           // the builder's, copying an echo (the frame is held, the parser idle)
   reg            rx_taken;         // the frame rx_valid shows has been parsed
   reg  [1:0]     rx_done_d;        // rx_done, two clocks on: the MAC shows the next frame
   reg            arp_pend;         // an ARP reply to arp_rep_* is owed
   reg  [47:0]    arp_rep_mac;
   reg  [31:0]    arp_rep_ip;
   reg            icmp_pend;        // an echo reply is owed; the frame stays held
   reg  [47:0]    icmp_rep_mac;
   reg  [31:0]    icmp_rep_ip;
   reg  [15:0]    icmp_len;         // its IP total length
   reg  [15:0]    icmp_sum;         // its checksum, adjusted

   // ------------------------------------------------------------------
   // Parsing: rx_addr runs ahead, pidx / pvalid describe rx_data
   // ------------------------------------------------------------------
   reg            pvalid;
   reg  [10:0]    pidx;
   reg            dst_is_mac, dst_is_bcast;
   reg  [47:0]    eth_src;
   reg  [15:0]    etype;
   reg            ip_vihl_ok;
   reg  [15:0]    ip_len;
   reg  [7:0]     ip_frag_hi;
   reg            ip_frag_ok;
   reg  [7:0]     ip_proto;
   reg  [31:0]    ip_src;
   reg            ip_dst_ok;
   reg  [19:0]    ip_sum;
   reg  [15:0]    arp_oper;
   reg  [47:0]    arp_smac;
   reg  [31:0]    arp_sip;
   reg  [31:0]    arp_tip;
   reg  [7:0]     icmp_type;
   reg  [15:0]    icmp_csum;
   reg  [15:0]    udp_sport;
   reg  [15:0]    udp_dport;
   reg  [15:0]    udp_len;
   reg            udp_pass;
   reg  [10:0]    plen;             // payload bytes delivered

   wire           eth_dst_ok = dst_is_mac | dst_is_bcast;
   wire [16:0]    ip_fold1   = {1'b0, ip_sum[15:0]} + {13'h0, ip_sum[19:16]};
   wire [15:0]    ip_fold2   = ip_fold1[15:0] + {15'h0, ip_fold1[16]};
   wire           ip_sum_ok  = ip_fold2 == 16'hffff;
   wire           ip_ok      = eth_dst_ok && etype == 16'h0800 && ip_vihl_ok && ip_frag_ok && ip_dst_ok && ip_sum_ok;
   wire           arp_pass   = eth_dst_ok && etype == 16'h0806 && arp_oper == 16'h0001 && arp_tip == IP;
   wire           icmp_pass  = ip_ok && ip_proto == 8'd1 && icmp_type == 8'd8 && ip_len >= 16'd28 &&
                               {1'b0, ip_len} + 17'd14 <= {6'h0, rx_len};
   wire [15:0]    udp_plen   = udp_len - 16'd8;
   wire [10:0]    rx_room    = rx_len - 11'd42;
   wire           udp_fits   = udp_plen <= {5'h0, rx_room};

   // the MAC byte k of a 48-bit address, 0 first on the wire
   function [7:0] mac_byte;
      input [47:0] m;
      input [2:0]  k;
      begin
         case (k)
            3'd0: mac_byte = m[47:40];
            3'd1: mac_byte = m[39:32];
            3'd2: mac_byte = m[31:24];
            3'd3: mac_byte = m[23:16];
            3'd4: mac_byte = m[15:8];
            default: mac_byte = m[7:0];
         endcase
      end
   endfunction

   function [7:0] ip_byte;
      input [31:0] a;
      input [1:0]  k;
      begin
         case (k)
            2'd0: ip_byte = a[31:24];
            2'd1: ip_byte = a[23:16];
            2'd2: ip_byte = a[15:8];
            default: ip_byte = a[7:0];
         endcase
      end
   endfunction

   // ------------------------------------------------------------------
   // Building: bi runs ahead, b2_idx / b2_v describe rx_data and b2_app
   // ------------------------------------------------------------------
   reg  [10:0]    bi;
   reg            b1_v, b2_v;
   reg  [10:0]    b1_idx, b2_idx;
   reg  [7:0]     b2_app;
   reg  [47:0]    rep_mac;
   reg  [31:0]    rep_ip;
   reg  [15:0]    rep_port;
   reg  [15:0]    tx_iplen;
   reg  [15:0]    tx_ulen;
   reg  [10:0]    flen;
   reg  [19:0]    hsum;
   reg  [15:0]    ipcsum;
   reg  [15:0]    icsum;
   reg            sum_pass;
   reg  [7:0]     fb;

   wire [16:0]    hs_fold1   = {1'b0, hsum[15:0]} + {13'h0, hsum[19:16]};
   wire [15:0]    hs_fold2   = hs_fold1[15:0] + {15'h0, hs_fold1[16]};
   wire [16:0]    ic_adj     = {1'b0, icmp_csum} + 17'h0800;   // type 8 became 0

   assign udp_tx_ready = bstate == B_IDLE && !arp_pend && !icmp_pend;
   assign rx_addr      = kind == K_ICMP && (bstate == B_SUM || bstate == B_FOLD || bstate == B_OUT) ? b_addr : p_addr;

   // the frame's byte b2_idx
   always @*
   begin
      fb = 8'h0;
      if (b2_idx < 11'd6)
         fb = mac_byte(rep_mac, b2_idx[2:0]);
      else if (b2_idx < 11'd12)
         fb = mac_byte(MAC, b2_idx[2:0] - 3'd6);
      else if (b2_idx == 11'd12)
         fb = 8'h08;
      else if (b2_idx == 11'd13)
         fb = kind == K_ARP ? 8'h06 : 8'h00;
      else if (kind == K_ARP)
      begin
         case (b2_idx)
            11'd14: fb = 8'h00;
            11'd15: fb = 8'h01;            // Ethernet
            11'd16: fb = 8'h08;
            11'd17: fb = 8'h00;            // IPv4
            11'd18: fb = 8'h06;
            11'd19: fb = 8'h04;
            11'd20: fb = 8'h00;
            11'd21: fb = 8'h02;            // reply
            11'd22, 11'd23, 11'd24, 11'd25, 11'd26, 11'd27:
                    fb = mac_byte(MAC, b2_idx[2:0] - 3'd6);
            11'd28, 11'd29, 11'd30, 11'd31:
                    fb = ip_byte(IP, b2_idx[1:0]);
            11'd32, 11'd33, 11'd34, 11'd35, 11'd36, 11'd37:
                    fb = mac_byte(rep_mac, b2_idx[2:0]);
            11'd38, 11'd39, 11'd40, 11'd41:
                    fb = ip_byte(rep_ip, b2_idx[1:0] - 2'd2);
            default: fb = 8'h00;
         endcase
      end
      else
      begin
         case (b2_idx)
            11'd14: fb = 8'h45;
            11'd15: fb = 8'h00;
            11'd16: fb = tx_iplen[15:8];
            11'd17: fb = tx_iplen[7:0];
            11'd18: fb = 8'h00;
            11'd19: fb = 8'h00;
            11'd20: fb = 8'h40;            // don't fragment
            11'd21: fb = 8'h00;
            11'd22: fb = 8'h40;            // TTL 64
            11'd23: fb = kind == K_ICMP ? 8'h01 : 8'h11;
            11'd24: fb = sum_pass ? 8'h00 : ipcsum[15:8];
            11'd25: fb = sum_pass ? 8'h00 : ipcsum[7:0];
            11'd26, 11'd27, 11'd28, 11'd29:
                    fb = ip_byte(IP, b2_idx[1:0] - 2'd2);
            11'd30, 11'd31, 11'd32, 11'd33:
                    fb = ip_byte(rep_ip, b2_idx[1:0] - 2'd2);
            11'd34: fb = kind == K_ICMP ? 8'h00 : UDP_PORT[15:8];
            11'd35: fb = kind == K_ICMP ? rx_data : UDP_PORT[7:0];
            11'd36: fb = kind == K_ICMP ? icsum[15:8] : rep_port[15:8];
            11'd37: fb = kind == K_ICMP ? icsum[7:0] : rep_port[7:0];
            11'd38: fb = kind == K_ICMP ? rx_data : tx_ulen[15:8];
            11'd39: fb = kind == K_ICMP ? rx_data : tx_ulen[7:0];
            11'd40: fb = kind == K_ICMP ? rx_data : 8'h00;
            11'd41: fb = kind == K_ICMP ? rx_data : 8'h00;
            default: fb = kind == K_ICMP ? rx_data : b2_app;
         endcase
      end
   end

   always @(posedge clk or negedge rst_n)
   begin
      if (!rst_n)
      begin
         pstate        <= P_IDLE;
         bstate        <= B_IDLE;
         rx_taken      <= 1'b0;
         rx_done_d     <= 2'b00;
         arp_pend      <= 1'b0;
         icmp_pend     <= 1'b0;
         p_addr        <= 11'h0;
         b_addr        <= 11'h0;
         rx_done       <= 1'b0;
         tx_we         <= 1'b0;
         tx_start      <= 1'b0;
         udp_rx_strobe <= 1'b0;
         accepted      <= 1'b0;
         pvalid        <= 1'b0;
         b1_v          <= 1'b0;
         b2_v          <= 1'b0;
         udp_pass      <= 1'b0;
      end
      else
      begin
         rx_done       <= 1'b0;
         tx_we         <= 1'b0;
         tx_start      <= 1'b0;
         udp_rx_strobe <= 1'b0;
         accepted      <= 1'b0;
         rx_done_d <= {rx_done_d[0], rx_done};
         if (rx_done_d[1])
            rx_taken <= 1'b0;

         // ---------------------------------------------------------------
         // the parser
         // ---------------------------------------------------------------
         pvalid <= pstate == P_PARSE && p_addr < rx_len;
         pidx   <= p_addr;
         if (pvalid)
         begin
            if (pidx >= 11'd14 && pidx <= 11'd33)
               ip_sum <= ip_sum + (pidx[0] ? {12'h0, rx_data} : {4'h0, rx_data, 8'h0});
            case (pidx)
               11'd0, 11'd1, 11'd2, 11'd3, 11'd4, 11'd5:
               begin
                  if (rx_data != mac_byte(MAC, pidx[2:0]))
                     dst_is_mac <= 1'b0;
                  if (rx_data != 8'hff)
                     dst_is_bcast <= 1'b0;
               end
               11'd6, 11'd7, 11'd8, 11'd9, 11'd10, 11'd11:
                  eth_src <= {eth_src[39:0], rx_data};
               11'd12, 11'd13:
                  etype <= {etype[7:0], rx_data};
               11'd14:
                  ip_vihl_ok <= rx_data == 8'h45;
               11'd16, 11'd17:
                  ip_len <= {ip_len[7:0], rx_data};
               11'd20:
               begin
                  ip_frag_hi  <= rx_data;
                  arp_oper    <= {arp_oper[7:0], rx_data};
               end
               11'd21:
               begin
                  ip_frag_ok  <= ip_frag_hi[5:0] == 6'h0 && rx_data == 8'h00;
                  arp_oper    <= {arp_oper[7:0], rx_data};
               end
               11'd22:
                  arp_smac <= {arp_smac[39:0], rx_data};
               11'd23:
               begin
                  ip_proto <= rx_data;
                  arp_smac <= {arp_smac[39:0], rx_data};
               end
               11'd24, 11'd25:
                  arp_smac <= {arp_smac[39:0], rx_data};
               11'd26, 11'd27:
               begin
                  ip_src   <= {ip_src[23:0], rx_data};
                  arp_smac <= {arp_smac[39:0], rx_data};
               end
               11'd28, 11'd29:
               begin
                  ip_src   <= {ip_src[23:0], rx_data};
                  arp_sip  <= {arp_sip[23:0], rx_data};
               end
               11'd30, 11'd31:
               begin
                  arp_sip  <= {arp_sip[23:0], rx_data};
                  if (rx_data != ip_byte(IP, pidx[1:0] - 2'd2))
                     ip_dst_ok <= 1'b0;
               end
               11'd32, 11'd33:
                  if (rx_data != ip_byte(IP, pidx[1:0] - 2'd2))
                     ip_dst_ok <= 1'b0;
               11'd34:
               begin
                  icmp_type <= rx_data;
                  udp_sport <= {udp_sport[7:0], rx_data};
               end
               11'd35:
                  udp_sport <= {udp_sport[7:0], rx_data};
               11'd36, 11'd37:
               begin
                  icmp_csum <= {icmp_csum[7:0], rx_data};
                  udp_dport <= {udp_dport[7:0], rx_data};
               end
               11'd38, 11'd39:
               begin
                  udp_len <= {udp_len[7:0], rx_data};
                  arp_tip <= {arp_tip[23:0], rx_data};
               end
               11'd40:
                  arp_tip <= {arp_tip[23:0], rx_data};
               11'd41:
               begin
                  arp_tip <= {arp_tip[23:0], rx_data};
                  // everything a UDP payload needs is known: let it through
                  udp_pass        <= ip_ok && ip_proto == 8'd17 && udp_dport == UDP_PORT &&
                                     udp_len >= 16'd9 && rx_len >= 11'd43;
                  plen            <= udp_fits ? udp_plen[10:0] : rx_room;
                  udp_rx_src_mac  <= eth_src;
                  udp_rx_src_ip   <= ip_src;
                  udp_rx_src_port <= udp_sport;
               end
               default: ;
            endcase
            if (udp_pass && pidx >= 11'd42 && pidx < 11'd42 + plen)
            begin
               udp_rx_strobe <= 1'b1;
               udp_rx_byte   <= rx_data;
               udp_rx_first  <= pidx == 11'd42;
               udp_rx_last   <= pidx == 11'd41 + plen;
            end
         end

         case (pstate)
            P_IDLE:
            begin
               if (rx_valid && !rx_taken)
               begin
                  rx_taken     <= 1'b1;
                  p_addr       <= 11'h0;
                  dst_is_mac   <= 1'b1;
                  dst_is_bcast <= 1'b1;
                  ip_dst_ok    <= 1'b1;
                  ip_sum       <= 20'h0;
                  udp_pass     <= 1'b0;
                  pstate       <= P_PARSE;
               end
            end

            P_PARSE:
            begin
               p_addr <= p_addr + 1'b1;
               if (pvalid && pidx == rx_len - 1'b1)
                  pstate <= P_DECIDE;
            end

            P_DECIDE:
            begin
               accepted <= arp_pass | icmp_pass | udp_pass;
               pstate   <= P_IDLE;
               if (icmp_pass && !icmp_pend)
               begin
                  icmp_pend    <= 1'b1;              // the frame stays held for the copy
                  icmp_rep_mac <= eth_src;
                  icmp_rep_ip  <= ip_src;
                  icmp_len     <= ip_len;
                  icmp_sum     <= ic_adj[15:0] + {15'h0, ic_adj[16]};
               end
               else
               begin
                  rx_done <= 1'b1;
                  if (arp_pass && !arp_pend)
                  begin
                     arp_pend    <= 1'b1;
                     arp_rep_mac <= arp_smac;
                     arp_rep_ip  <= arp_sip;
                  end
               end
            end

            default:
               pstate <= P_IDLE;
         endcase

         // ---------------------------------------------------------------
         // the builder
         // ---------------------------------------------------------------
         b1_v   <= 1'b0;
         b2_v   <= b1_v;
         b2_idx <= b1_idx;
         b2_app <= udp_tx_byte;

         case (bstate)
            B_IDLE:
            begin
               if (icmp_pend)
               begin
                  kind     <= K_ICMP;
                  rep_mac  <= icmp_rep_mac;
                  rep_ip   <= icmp_rep_ip;
                  tx_iplen <= icmp_len;
                  flen     <= icmp_len[10:0] + 11'd14;
                  icsum    <= icmp_sum;
                  bstate   <= B_WAIT;
               end
               else if (arp_pend)
               begin
                  kind     <= K_ARP;
                  rep_mac  <= arp_rep_mac;
                  rep_ip   <= arp_rep_ip;
                  flen     <= 11'd42;
                  arp_pend <= 1'b0;
                  bstate   <= B_WAIT;
               end
               else if (udp_tx_start)
               begin
                  kind     <= K_UDP;
                  rep_mac  <= udp_tx_dst_mac;
                  rep_ip   <= udp_tx_dst_ip;
                  rep_port <= udp_tx_dst_port;
                  tx_ulen  <= {5'h0, udp_tx_len} + 16'd8;
                  tx_iplen <= {5'h0, udp_tx_len} + 16'd28;
                  flen     <= udp_tx_len + 11'd42;
                  bstate   <= B_WAIT;
               end
            end

            B_WAIT:                                  // the MAC's transmitter free
            begin
               if (!tx_busy)
               begin
                  if (kind == K_ARP)
                  begin
                     bi       <= 11'h0;
                     sum_pass <= 1'b0;
                     bstate   <= B_OUT;
                  end
                  else
                  begin
                     bi       <= 11'd14;
                     hsum     <= 20'h0;
                     sum_pass <= 1'b1;
                     bstate   <= B_SUM;
                  end
               end
            end

            B_SUM:                                   // the IP header's checksum
            begin
               b_addr  <= bi;
               b1_idx  <= bi;
               b1_v    <= bi <= 11'd33;
               bi      <= bi + 1'b1;
               if (b2_v)
                  hsum <= hsum + (b2_idx[0] ? {12'h0, fb} : {4'h0, fb, 8'h0});
               if (b2_v && b2_idx == 11'd33)
                  bstate <= B_FOLD;
            end

            B_FOLD:
            begin
               ipcsum   <= ~hs_fold2;
               bi       <= 11'h0;
               sum_pass <= 1'b0;
               b2_v     <= 1'b0;
               bstate   <= B_OUT;
            end

            B_OUT:                                   // the frame into the MAC's buffer
            begin
               b_addr     <= bi;
               udp_tx_idx <= bi - 11'd42;
               b1_idx     <= bi;
               b1_v       <= bi < flen;
               bi         <= bi + 1'b1;
               if (b2_v)
               begin
                  tx_we   <= 1'b1;
                  tx_addr <= b2_idx;
                  tx_data <= fb;
               end
               if (b2_v && b2_idx == flen - 1'b1)
                  bstate <= B_SEND;
            end

            B_SEND:
            begin
               tx_start <= 1'b1;
               tx_len   <= flen;
               if (kind == K_ICMP)
               begin
                  rx_done   <= 1'b1;
                  icmp_pend <= 1'b0;
               end
               bstate   <= B_IDLE;
            end

            default:
               bstate <= B_IDLE;
         endcase
      end
   end

endmodule
