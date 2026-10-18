/*
==============================================================================
ttlc_fetch.v:  The TTLC's program sequencer and instruction fetch (replaces
               ttlc_inst_cache.v, 2026-10-17).

The program is 12-bit slots, four to a 48-bit group of three 16-bit words
(word 3g at the low end): slot k of group g is bits [12k+11:12k], an
instruction {address[7:0], opcode[3:0]} - a TTLC opcode needs its 8-bit
I/O address, so 12 bits hold it, and the 4-bit jump field of the old
one-word form was waste (the 6x2 elevator has no jmp at all).  A jmp takes
two slots: its own ({8'h0, 4'hc}) and the next, which holds the 12-bit
target group; the assembler keeps the pair inside a group and starts every
label on a group (slot 0).  The PC is {group[11:0], slot[1:0]}: a plain
instruction index for straight code.  The stack holds the PC after the
jmp's pair.

Two groups are buffered: A, the one executing, and B, the next one (or the
one a jump wants while A refills from it); each is fetched in one QSPI
burst of three words, and B is prefetched while A executes.  About the
flops of the old four-line cache (two 48-bit groups, the group numbers and
the two slot bits in the PC and the stack against four 28-bit lines), a
quarter less flash per instruction and a quarter fewer bursts.

The sequencer runs an instruction in two clocks, so that the core's own
pipeline (the instruction latched at the falling edge, executed at the
next rising one) never sees a second instruction behind a jump: ISSUE
presents the slot at pc with ready high and the top raises run; the core
latches it at the falling edge; EXEC holds ready low while the core
executes at its end, where the PC moves exactly once - by the jump's
target, the return, the nopf's reset, or on by one slot (two over a
skipped jmp).  The old RTL let the core's JMP level reload the PC and push
the stack on each of three clocks, and an uncached target zeroed the
address it reloaded from (seen in a trace on 2026-10-17; the elevator and
the loopback never jump, so nothing had run a jmp).
==============================================================================
*/
module ttlc_fetch
(
   input  wire          clk,
   input  wire          rst_n,

   // The sequencer
   input  wire          fetch_en,         // fetch from the flash (not halted)
   input  wire          run,              // the core takes the slot presented (mc14500_run)
   input  wire          jmp,              // the core's decoded JMP (its r_inst)
   input  wire          rtn,              // ... RTN
   input  wire          flag_f,           // a nopf executed (FLAG_F)
   output reg  [11:0]   inst,             // the slot at pc: {address[7:0], opcode[3:0]}
   output wire          ready,            // inst is the slot at pc, the core may take it
   output wire          exec,             // the taken slot executes (retires at this clock's end)
   output wire [13:0]   pc,               // {group, slot}

   // The QSPI controller
   output wire [13:0]   fetch_word,       // word address of the group being fetched (3 x group)
   input  wire [15:0]   qspi_rdata,
   output wire [15:0]   qspi_wdata,
   output wire [1:0]    qspi_wstrb,
   input  wire          qspi_ready,
   output reg           qspi_ready_ack,
   input  wire          qspi_xfer_done,
   output reg           qspi_valid,
   output wire [3:0]    qspi_xfer_len,
   input  wire          invalidate,       // the program changed: drop the groups
   output wire          invalidate_ack
);

   localparam [1:0] ST_IDLE      = 2'd0;
   localparam [1:0] ST_LOAD      = 2'd1;
   localparam [1:0] ST_LOAD_NEXT = 2'd2;
   localparam [1:0] ST_LOAD_DONE = 2'd3;

   reg   [11:0]         grp;              // the group of A, the PC's group
   reg   [1:0]          slot;
   reg   [47:0]         buf_a;
   reg                  a_valid;
   reg   [47:0]         buf_b;
   reg   [11:0]         b_grp;            // the group B holds, or is being filled with
   reg                  b_valid;
   reg                  fresh;            // inst is the slot at pc from a valid A
   reg                  ex;               // EXEC: the core executes the slot taken
   reg   [14:0]         stack [3:0];      // {valid, pc}
   reg   [1:0]          state;
   reg   [1:0]          state_next;
   reg                  fill_start;
   reg                  fill_word;
   reg                  fill_done;

   wire  [11:0]         cur_slot  = buf_a[slot * 12 +: 12];
   wire  [1:0]          slot_p1   = slot + 2'd1;
   wire  [11:0]         jmp_tgt   = buf_a[slot_p1 * 12 +: 12];   // the pair's second slot
   wire                 op_is_jmp = inst[3:0] == 4'hc;
   wire  [13:0]         pc_inc    = pc + (op_is_jmp ? 14'd2 : 14'd1);
   wire  [13:0]         pc_next   = flag_f ? 14'd0 :
                                    jmp    ? {jmp_tgt, 2'b00} :
                                    rtn    ? stack[0][13:0] : pc_inc;
   wire  [11:0]         grp_p1    = grp + 12'd1;
   wire                 promote   = !a_valid && b_valid && b_grp == grp;
   wire  [11:0]         want_grp  = a_valid ? grp_p1 : grp;
   wire                 want_fill = !(b_valid && b_grp == want_grp) && !promote;

   assign pc             = {grp, slot};
   assign ready          = fresh && a_valid && !ex;
   assign exec           = ex;
   assign fetch_word     = {b_grp, 1'b0} + {1'b0, b_grp};        // 3 x group
   assign qspi_xfer_len  = 4'h2;                                  // three words
   assign qspi_wstrb     = 2'b00;
   assign qspi_wdata     = 16'h0;
   assign invalidate_ack = invalidate && !a_valid && !b_valid && state == ST_IDLE;

   // ==========================================================================
   // The sequencer: the PC, the stack, group A and the presented slot
   // ==========================================================================
   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         grp      <= 12'h0;
         slot     <= 2'h0;
         buf_a    <= 48'h0;
         a_valid  <= 1'b0;
         fresh    <= 1'b0;
         ex       <= 1'b0;
         inst     <= 12'h0;
         stack[0] <= 15'h0;
         stack[1] <= 15'h0;
         stack[2] <= 15'h0;
         stack[3] <= 15'h0;
      end
      else
      begin
         inst  <= cur_slot;
         fresh <= a_valid;
         if (invalidate)
         begin
            a_valid <= 1'b0;
            fresh   <= 1'b0;
         end
         else if (promote)
         begin
            buf_a   <= buf_b;
            a_valid <= 1'b1;
            fresh   <= 1'b0;
         end

         if (ex)
         begin
            // the core executes the slot at this edge: the PC moves once
            ex <= 1'b0;
            if (jmp)
            begin
               stack[0] <= {1'b1, pc + 14'd2};
               stack[1] <= stack[0];
               stack[2] <= stack[1];
               stack[3] <= stack[2];
            end
            else if (rtn)
            begin
               stack[0] <= stack[1];
               stack[1] <= stack[2];
               stack[2] <= stack[3];
               stack[3] <= 15'h0;
            end
            slot <= pc_next[1:0];
            if (pc_next[13:2] != grp)
            begin
               grp     <= pc_next[13:2];
               a_valid <= 1'b0;             // A refills from B (promote) or the flash
            end
            fresh <= 1'b0;
         end
         else if (ready && run)
            ex <= 1'b1;                     // the core latched it at the falling edge
      end
   end

   // ==========================================================================
   // Group B: filled from the flash, three words a burst; promoted to A
   // ==========================================================================
   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         buf_b   <= 48'h0;
         b_grp   <= 12'h0;
         b_valid <= 1'b0;
         state   <= ST_IDLE;
      end
      else
      begin
         state <= state_next;
         if (fill_start)
         begin
            b_grp   <= want_grp;
            b_valid <= 1'b0;
         end
         if (fill_word)
            buf_b <= {qspi_rdata, buf_b[47:16]};
         if (fill_done)
            b_valid <= !invalidate;
         if (promote || (invalidate && state == ST_IDLE))
            b_valid <= 1'b0;
      end
   end

   always @*
   begin
      state_next     = state;
      fill_start     = 1'b0;
      fill_word      = 1'b0;
      fill_done      = 1'b0;
      qspi_valid     = 1'b0;
      qspi_ready_ack = 1'b1;
      case (state)
         ST_IDLE:
            if (fetch_en && want_fill && !invalidate)
            begin
               fill_start = 1'b1;
               state_next = ST_LOAD;
            end
         ST_LOAD:
            if (qspi_ready)
            begin
               fill_word = 1'b1;
               if (!qspi_xfer_done)
               begin
                  qspi_valid = 1'b1;
                  state_next = ST_LOAD_NEXT;
               end
               else
                  state_next = ST_LOAD_DONE;
            end
            else
               qspi_valid = 1'b1;
         ST_LOAD_NEXT:
            begin
               qspi_valid = 1'b1;
               if (!qspi_ready)
                  state_next = ST_LOAD;
            end
         ST_LOAD_DONE:
            begin
               fill_done  = 1'b1;
               state_next = ST_IDLE;
            end
         default:
            state_next = ST_IDLE;
      endcase
   end

endmodule
