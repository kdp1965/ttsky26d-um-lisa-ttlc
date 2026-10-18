/*
==============================================================================
lisa_core.v:  Little ISA (LISA) 8-bit processor core.

Copyright 2024 by Ken Pettit <pettitkd@gmail.com>

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
SUCH DAMAGE.

==============================================================================
*/

/*
==========================================================================================
LISA: Little Instruction Set Architecture.

Uses a 14 (or 16) bit program word.  Shown is the 14-bit version.  For 16-bit, everything
(or almost everything) shifts left 2 bits to give a larger instruction and data space.

  Jump and Link
    0 ppppppppppppp    jmp   pmem13         pc <= pmem12, ra <= pc + 1
                                             
  Immediate Ops                              
    10 0000 iiiiiiii   ldi #imm8            a <= imm8, c <= 0, z <= (a==0)
    10 0011 iiiiiiii   ret #imm8            a <= imm8, pc <= stack
    10 0010 100xxxxx   ret                  pc <= stack
    10 0010 1100xxxx   rc                   If c==1, pc <= stack
    10 0010 1101xxxx   rets                 Return from ISR
    10 0010 1110xxxx   rz                   If z==1, pc <= stack
    10 0010 10100000   call ix              Call ix, ix <= ix + 1 (used for printf, etc.)
    10 0010 10101000   jmp ix               Jump to ix
    10 0010 10110000   xchg ra              Swap ix with ra
    10 0010 10110001   xchg ia              Swap ix with ia (Interrupt Address)
    10 0010 10110010   xchg sp              Swap ix with sp
    10 0010 10110011   spix                 ix <= sp
    10 0010 10110100   cpx  ra              Compare ix and ra
    10 0010 10110110   cpx  sp              Compare ix and sp
                                            
    10 0001 siiiiiii   mulu  [ix/sp+imm7]   {dstack[0] , a} <= a * M[ix/sp+#imm7]
    10 0100 iiiiiiii   adc #imm8            a <= a + imm8 + c, c and z set appropriately
    10 0101 iiiiiiii   ads #imm8            sp <= sp + signed(imm8)
    10 0110 iiiiiiii   adx #imm8            ix <= ix + signed(imm8)
    10 0111 siiiiiii   dcx #imm7            M[ix/sp + #imm8]--
 
  Direct Ops
    10 1000 00000000   shl                  a <<= 1
    10 1000 00000001   shr                  a >>= 1
    10 1000 0000001b   ldc   #imm1          Load cflag with b
    10 1000 000010ii   shl16                {a,temp} <<= 1
    10 1000 000011ii   shr16                {a,temp} >>= 1
    10 1000 000001ux   txa                  Transfer IX[7:0]/IX[14:8] to A based on u
    10 1000 00010bbb   btst  a,#b           Bit test:  c = a[#b] 
    10 1000 000110cb   ldz                  Load zflag: Complement if C, otherwise zflag = b
    10 1000 00011100   nop
    10 1000 00011101   notz
    10 1000 00011110   ei/di                Enable/Disable Interrupt as per inst[0]
    10 1000 00011111   brk                  Software breakpoint
    10 1000 00100xxx   push a               Push acc to stack: sp--, M[sp] <= a
    10 1000 00110xxx   pop a                Pop acc from stack: a <= M[sp], sp++
    10 1000 010000ux   tax                  Transfer A to IX[7:0]/IX[14:8] based on u
    10 1000 01001000   ldirq                A <= {irq_z, irq_c}
    10 1000 01001001   stirq                {irq_z, irq_c} <= A
    10 1000 010100mm   amode                Set arithemetc mode ([signed:shift])
    10 1000 01011000   sra                  Save Return Address: M[sp-1] <= ra[7:0], M[sp-2] <= {cond, ra[14:8]}, sp -= 2
    10 1000 01011001   lra                  Load Return Address: {cond, ra[14:8]} <= M[sp], ra[7:0] <= M[sp+1], sp += 2
    10 1000 01011010   push ix              Push ix to stack (as sra: ix[7:0] at sp-1, {ix_cond, ix[14:8]} at sp-2)
    10 1000 01011011   pop ix               Pop ix from stack (as lra)
    10 1000 01011100   lddiv                Load dividend from stack: ra[7:0]<=n(sp) (n in the 2nd word) ix[7:0]<=a
    10 1000 01011110   savec                Save cflag
    10 1000 01011111   restc                Restore cflag
    10 1000 01100000   ldx                  Load ix with data in next opcode
    10 1000 01101c00   addax                Add acc to IX with carry
    10 1000 01101001   addaxu               Add acc to IX MSB
    10 1000 01101c10   subax                Subtract acc from IX with borrow
    10 1000 01101011   subaxu               Subtract acc from IX MSB
    10 1000 01110iii   ldac                 Load a with condtion flag
    10 1000 01111ooooo Fops                 Floating Point ops
    10 1000 10sttccc   if    type, cond     Set cond processing based on type and condition
    10 1000 110000dv   div                  Do signed/unsigned division (depending on amode[1])
    10 1000 110001dv   rem                  Do signed/unsigned remainder (depending on amode[1])
    10 1001 xxxxxxxx   cpi   a,#imm8        Compare A with immediate data, signed/unsigned depending on amode[1]

  Floating Point ops
    10 1000 01111000 0h tfa                 Transfer facc (half) to acc
    10 1000 01111000 1h taf                 Transfer a to facc (half)

    10 1000 01111001 ff fmul                Float mult facc * fx.  Result in facc
    10 1000 01111010 ff fadd                Float add  facc + fx.  Result in facc
    10 1000 01111011 ff fneg                Negate fx.  Result in fx
    10 1000 01111100 ff fswqp               Swap facc and fx.
    10 1000 01111101 ff fcmp                Compare facc and fx
    10 1000 01111110 ff fdiv                Divide facc / fx (reserved for future, not implemented yet)
    10 1000 1100100000  itof                Convert 16-bit facc to bfloat facc
    10 1000 1100100001  ftoi                Convert 16-bit facc to bfloat facc
    10 1000 1100100010  fclr                facc <= 0

  Relative branch
    10 101b bbbbbbbb   bz    #imm9          Branch (+255 / -256) if zflag == 0
    10 110b bbbbbbbb   br    #imm9          Branch (+255 / -256)
    10 111b bbbbbbbb   bnz   #imm9          Branch (+255 / -256) if zflag != 0

  Indirect, Arithmetic and logical ops
    11 0000 siiiiiii   add   a,[ix/sp+#imm7]    Unsigned add:  a <= a + M[ix/sp+#imm7] + c
    11 0001 siiiiiii   mul   [ix/sp+imm7]       {dstack[0] , a} <= a * M[ix/sp+#imm7]
    11 0010 siiiiiii   sub   a,[ix/sp+#imm7]    Unsigned subtract  a <= a - M[ix/sp+#imm7] - c
    11 0011 0iiiiiii   ldxx  #imm7              ix <= M[sp + #imm7]
    11 0011 1iiiiiii   stxx  #imm7              M[sp + #imm7] <= ix
    11 0100 siiiiiii   and   a,[ix/sp+#imm7]
    11 0101 iiiiiiii   andi  a,#imm8            a <= a AND #imm7
    11 0110 siiiiiii   or    a,[ix/sp+#imm7]
    11 0111 piiiiiii   swapi a,[#imm8]          a <=> mem[#imm7]
    11 1000 siiiiiii   xor   a,[ix/sp+#imm7]
    11 1001 siiiiiii   inx   #imm7(ix/sp)       M[ix/sp + #imm7]++
    11 1010 siiiiiii   cmp   a,[ix/sp+#imm7]    Unsigned compare: c = a<M[ix+#imm7], z = a==M[ix+#imm7]
    11 1011 siiiiiii   swap  a,[ix/sp+#imm7]    a <=> mem[ix+#imm7]
    11 1100 siiiiiii   ldax  [ix/sp+imm7]       a <= mem[ix+#imm7]
    11 1101 piiiiiii   lda   [imm8]             a <= mem[#imm7], p specifies upper 128 or lower 128 bytes
    11 1110 siiiiiii   stax  [ix/sp+imm7]       M[ix+#imm7] <= a
    11 1111 piiiiiii   sta   [imm8]             M[ix+#imm7] <= a

  States
    00  Fetch Instruction
    01  Decode
    10  Execute / increment PC
    11  Stage 2 execute for 2-cycle opcodes

  Signed Comparisions:
    acc      cmp(b)    unsigned   cflag   signed    inverted
    0xFF     0xFE      a gt b       0     a gt b       0
    0xFE     0xFF      a lt b       1     a lt b       0
    0xFE     0x0F      a gt b       0     a lt b       1
    0x0F     0xFE      a lt b       1     a gt b       1

==========================================================================================
*/

`define PWORD_SIZE      16
`define WANT_BF16

module lisa_core
#(
      parameter WANT_MUL       = 1,
      parameter WANT_DIV       = 1,
      parameter PC_BITS        = 15,
      parameter D_BITS         = 15,       // NOTE: Up to PC_BITS
      parameter WANT_DBG       = 1,
      parameter DBG_BRKPOINTS  = 6
)
(
`ifdef USE_POWER_PINS
    input                  VPWR,
    input                  VGND,
`endif
   input                      clk,
   input                      rst_n,
   input                      rst_async_n,
   input                      reset,

   // Address bus
   input  wire [`PWORD_SIZE-1:0] inst_i,
   input  wire                   inst_ready,
   output wire                   i_fetch,
   output wire [PC_BITS-1:0]     i_addr,
   output wire [`PWORD_SIZE-1:0] inst_o,
   output wire                   inst_we,

   // Data bus
   (* keep = "true" *)
   input  wire [7:0]          d_i,
   (* keep = "true" *)
   output reg  [7:0]          d_o,
   (* keep = "true" *)
   output wire [D_BITS-1:0]   d_addr,
   output wire                d_periph,
   (* keep = "true" *)
   output wire                d_we,
   (* keep = "true" *)
   output wire                d_rd,
   (* keep = "true" *)
   output wire                d_valid,
   (* keep = "true" *)
   input  wire                d_ready,

   input  wire [7:0]          int_i,      // NEW Interrupt inputs
   input  wire [7:0]          int_en,     // NEW Interrupt inputs

   input  wire [7:0]          dbg_a,
   input  wire [15:0]         dbg_di,
   output wire [15:0]         dbg_do,
   input  wire                dbg_we,
   input  wire                dbg_rd,
   output wire                dbg_ready,
   output wire                dbg_halted
);

   localparam  D_INST = D_BITS > 10 ? 10 : D_BITS;
   localparam  D_STCK = D_BITS > 9 ? 9 : D_BITS;

   reg  [`PWORD_SIZE-1:0]     inst_r;
   (* keep = "true" *)
   wire [`PWORD_SIZE-1:0]     inst;
   (* keep = "true" *)
   reg  [7:0]                 acc;
   (* keep = "true" *)
   wire [PC_BITS-1:0]         ix;
   reg  [PC_BITS-1:0]         ix_val;
   wire                       ix_cond;
   reg                        ix_load;
   reg                        ix_cond_val;
   (* keep = "true" *)
   reg  [D_BITS-1:0 ]         sp;
   wire                       cflag;
   reg                        cflag_save;
   reg                        cflag_isr;
   reg                        cflag_save_isr;         // the ISR shadows of what rets restores:
   reg  [2:0]                 amode_isr;              // cflag_save, amode, the live signed inversion
   reg                        signed_inv_live_isr;
   wire                       signed_inversion;
   reg                        signed_valid;
   reg                        signed_inv_save;
   reg                        signed_inv_isr;
   reg                        zflag_isr;
   wire                       zflag;
   reg  [2:0]                 state;
   (* keep = "true" *)
   reg  [PC_BITS-1:0]         pc;
   (* keep = "true" *)
   wire [PC_BITS-1:0]         ra;                     // Return Address
   reg  [PC_BITS-1:0]         ra_val;                 // Return Address
   wire                       ra_cond;
   reg                        ra_cond_val;
   reg                        ra_load;
   reg                        isr_jump;
   (* keep = "true" *)
   reg  [1:0]                 cond;
   reg                        acc_delayed_load;
   reg  [8:0]                 acc_load_val;
   reg  [2:0]                 amode;
   reg                        stage_two;
   reg                        delayed_sp_dec;
   wire                       ldx_stage_two;
   wire                       d_o_shr_val;
   reg                        lddiv_stage_two;
   reg                        div_stage_two;
   reg                        rem_stage_two;
   reg  [PC_BITS-1:0]         ia;                     // Interrupt Address
   reg                        ie;                     // Interrupt enable

   wire                       jump_taken;
   wire                       br_taken;
   wire                       ret_taken;
   wire                       ret_isr;
   reg                        jump_taken_r;
   reg                        br_taken_r;
   reg                        ret_taken_r;
   reg                        ret_isr_r;
   wire [PC_BITS-1:0]         pc_inc;
   wire [PC_BITS-1:0]         pc_rel;
   wire [PC_BITS-1:0]         ix_sum;
   wire [PC_BITS-1:0]         ix_addr;
   wire [D_BITS-1:0]          sp_sum;
   wire [D_BITS-1:0]          sp_addr;
   wire [D_BITS-1:0]          sp_adder;
   wire [8:0]                 acc_sum;
   reg  [7:0]                 acc_adder;
   wire [15:0]                acc_mul;
   wire signed [15:0]         acc_muls;
   wire                       non_acc_d_o;
   wire                       sp_sum_op;
   wire                       stg2_state;
   wire                       fetch_state;
   wire                       predec_state;
   wire                       decode_state;
   wire                       exec_state;
   wire                       c_load;
   reg                        c_val;
   wire                       c_cpi;
   wire                       d_addr_imm;
   reg                        d_ready_r;
   reg                        cond_load;
   reg  [7:0]                 acc_misc;
   reg  [7:0]                 acc_delayed_val;
   reg  [7:0]                 acc_delayed_val_val;
   reg                        acc_delayed_val_load;
   reg                        acc_ld_misc;
`ifdef SIMULATION
   wire                       op_ret;
   wire                       op_rets;
   wire                       op_rc;
   wire                       op_rz;
`endif
   wire                       op_adx;
   wire                       op_ldx;
   wire                       op_addax;
   wire                       op_addaxu;
   wire                       op_subax;
   wire                       op_subaxu;
   wire                       op_ldi;
   wire                       op_reti;
   wire                       op_adc;
   wire                       op_ads;
   wire                       op_tax;
   wire                       op_taxu;
   wire                       op_call_ix;
   wire                       op_jmp_ix;
   wire                       op_call;
   wire                       op_xchg_sp;
   wire                       op_xchg_ra;
   wire                       op_xchg_ia;
   wire                       op_cpx_ra;
   wire                       op_cpx_sp;
   wire                       op_spix;
   wire                       op_push_a;
   wire                       op_pop_a;
   wire                       op_lddiv;
   wire                       op_savec;
   wire                       op_restc;
   wire                       op_mul;
   wire                       op_mulu;
   wire                       op_cpi;
   wire                       op_cmp;
   wire                       op_if;
   wire                       op_btst;
   wire                       op_swap;
   wire                       op_swapi;
   wire                       op_sra;
   wire                       op_lra;
   wire                       op_ldirq;
   wire                       op_stirq;
   wire                       op_push_ix;
   wire                       op_pop_ix;
   wire                       op_st;
   wire                       op_sta;
   wire                       op_lda;
   wire                       op_ld_misc;
   wire                       op_ldac;
   wire                       op_dcx;
   wire                       op_inx;
   wire                       op_ldxx;
   wire                       op_stxx;
   wire                       op_txa;
   wire                       op_txau;
   wire                       op_shl;
   wire                       op_shr;
   wire                       op_ldc;
   wire                       op_shl16;
   wire                       op_shr16;
   wire                       op_div;
   wire                       op_rem;
   wire                       op_any_div;
   wire                       op_ldz;
   wire                       op_brk;
   wire                       op_eidi;
   wire                       op_notz;
   wire                       op_amode;
   wire                       op_ldamode;
   (* keep="true" *)
   wire                       op_div_start;
   reg                        op_div_start_r;
   wire                       op_add;
   wire                       op_sub;
   wire                       op_and;
   wire                       op_andi;
   wire                       op_or;
   wire                       op_xor;
   wire                       op_ldax;

   reg                        op_adx_r;
   reg                        op_ldx_r;
   reg                        op_addax_r;
   reg                        op_addaxu_r;
   reg                        op_subax_r;
   reg                        op_subaxu_r;
   reg                        op_ldi_r;
   reg                        op_reti_r;
   reg                        op_adc_r;
   reg                        op_ads_r;
   reg                        op_tax_r;
   reg                        op_taxu_r;
   reg                        op_call_ix_r;
   reg                        op_jmp_ix_r;
   reg                        op_call_r;
   reg                        op_xchg_sp_r;
   reg                        op_xchg_ra_r;
   reg                        op_xchg_ia_r;
   reg                        op_cpx_ra_r;
   reg                        op_cpx_sp_r;
   reg                        op_spix_r;
   reg                        op_push_a_r;
   reg                        op_pop_a_r;
   reg                        op_lddiv_r;
   reg                        op_savec_r;
   reg                        op_restc_r;
   reg                        op_mul_r;
   reg                        op_mulu_r;
   reg                        op_cpi_r;
   reg                        op_cmp_r;
   reg                        op_if_r;
   reg                        op_btst_r;
   reg                        op_swap_r;
   reg                        op_swapi_r;
   reg                        op_sra_r;
   reg                        op_lra_r;
   reg                        op_ldirq_r;
   reg                        op_stirq_r;
   reg                        op_push_ix_r;
   reg                        op_pop_ix_r;
   reg                        op_st_r;
   reg                        op_sta_r;
   reg                        op_lda_r;
   reg                        op_ld_misc_r;
   reg                        op_ldac_r;
   reg                        op_dcx_r;
   reg                        op_inx_r;
   reg                        op_ldxx_r;
   reg                        op_stxx_r;
   reg                        op_txa_r;
   reg                        op_txau_r;
   reg                        op_shl_r;
   reg                        op_shr_r;
   reg                        op_ldc_r;
   reg                        op_shl16_r;
   reg                        op_shr16_r;
   reg                        op_div_r;
   reg                        op_rem_r;
   reg                        op_ldz_r;
   reg                        op_brk_r;
   reg                        op_eidi_r;
   reg                        op_notz_r;
   reg                        op_amode_r;
   reg                        op_ldamode_r;
   (* keep="true" *)
   reg                        op_add_r;
   reg                        op_sub_r;
   reg                        op_and_r;
   reg                        op_andi_r;
   reg                        op_or_r;
   reg                        op_xor_r;
   reg                        op_ldax_r;

`ifdef WANT_BF16
   wire                       op_fops;
   wire                       op_tfa;
   wire                       op_taf;
   wire                       op_fmul;
   wire                       op_fdiv;
   wire                       op_fadd;
   wire                       op_fneg;
   wire                       op_fswap;
   wire                       op_itof;
   wire                       op_ftoi;
   wire                       op_fclr;
   wire                       op_fcmp;
   reg                        op_tfa_r;
   reg                        op_taf_r;
   reg                        op_fmul_r;
   reg                        op_fdiv_r;
   reg                        op_fadd_r;
   reg                        op_fneg_r;
   reg                        op_fswap_r;
   reg                        op_itof_r;
   reg                        op_ftoi_r;
   reg                        op_fclr_r;
   reg                        op_fcmp_r;
   (* keep = "true" *)
   reg   [15:0]               facc;
   reg   [15:0]               f0;
   reg   [15:0]               f1;
   reg   [15:0]               f2;
   reg   [15:0]               f3;
   reg   [15:0]               fx[3:0];
   wire  [15:0]               fmul_result;
   wire  [15:0]               fdiv_result;
   wire                       fdiv_ready;
   wire                       fdiv_complete;
   wire                       fdiv_valid;
   wire  [15:0]               fadd_result;
   wire  [7:0]                f_half[1:0];
`endif
   reg   [1:0]                div_args;
   (* keep = "true" *)
   wire  [15:0]               div_divisor;
   (* keep = "true" *)
   wire  [15:0]               div_dividend;
   wire  [15:0]               div_result;
   wire                       div_ready;
   wire                       d_valid_rd;
   wire                       d_ok;

   // Debugger signals
   reg                        d_we_r;
   wire [7:0]                 dbg_d_o;
   wire [D_BITS-1:0]          dbg_d_addr;
   wire                       dbg_d_access;
   wire                       dbg_d_periph;
   wire                       dbg_d_rd;
   wire                       dbg_inc;
   reg                        dbg_inc_r;
   wire                       dbg_ready_c;
   wire                       stop;
   wire                       cont_q;
   wire                       cflag_load;
   wire                       signed_inv_val;
   reg                        zflag_val;
   reg                        zflag_load;      // (declared here: the ISR shadows read them before the flag logic below; icarus elaborates in order)
   wire                       irq_pending;            // an enabled interrupt the instruction in exec can give way to
   wire                       irq_take;               // ... and it does, this clock
   wire                       stg2_next;              // the instruction in exec goes on to its second stage

   assign inst = (inst_ready & !d_we_r) ? inst_i : inst_r;

   // An interrupt is taken after an instruction that leaves no predicate and
   // no second word pending: not after if/iftt/ifte, nor the first word of
   // ldx, lddiv or a two-word div/rem (TT07 took it there too, and lost the
   // predicate or ran the literal as an opcode after rets).
   assign stg2_next   = (cond[0] && (op_sra_r | op_lra_r | op_push_ix_r | op_pop_ix_r | op_stxx_r | op_ldxx_r | op_fdiv_r |
                                     (op_any_div & inst_r[0]))) || div_stage_two || rem_stage_two || op_fops;
   // Nor after ei/di, stirq or xchg ia, whose effect the entry would undo.
   assign irq_pending = ie & cond[1] & |(int_i & int_en) &
                        ~(cond[0] & (op_if_r | op_ldx_r | op_lddiv_r | (op_any_div & ~inst[0]) |
                                     op_eidi_r | op_stirq_r | op_xchg_ia_r));
   assign irq_take    = exec_state & d_ok & ~stg2_next & irq_pending;
   assign fetch_state  = state == 3'b000;
   assign predec_state = state == 3'b001;
   assign decode_state = state == 3'b010;
   assign exec_state   = state == 3'b011;
   assign stg2_state   = state == 3'b100;

   assign jump_taken =  inst[`PWORD_SIZE-1]      == 1'b0;                        // JMP
   assign br_taken   = (inst[`PWORD_SIZE-1 -: 5] == 5'b10110)               ||   // BR
                       (inst[`PWORD_SIZE-1 -: 5] == 5'b10101 && zflag != 1) ||   // BNZ
                       (inst[`PWORD_SIZE-1 -: 5] == 5'b10111 && zflag == 1);     // BZ
   assign ret_taken = ((inst[`PWORD_SIZE-1 -: 6] == 6'b100011) ||
                       (inst[`PWORD_SIZE-1 -: 9] == 9'b100010100) ||                   // RET
                       (inst[`PWORD_SIZE-1 -: 10] == 10'b1000101100 && cflag == 1) ||   // RC
                       (inst[`PWORD_SIZE-1 -: 10] == 10'b1000101110 && zflag == 1));    // RZ
   assign ret_isr   =  (inst[`PWORD_SIZE-1 -: 10] == 10'b1000101101);                  // RETS
`ifdef SIMULATION
   assign op_ret      = inst[`PWORD_SIZE-1 -: 9] == 9'b100010100;
   assign op_rc       = inst[`PWORD_SIZE-1 -: 10] == 10'b1000101100;
   assign op_rets     = inst[`PWORD_SIZE-1 -: 10] == 10'b1000101101;                  // RETS
   assign op_rz       = inst[`PWORD_SIZE-1 -: 10] == 10'b1000101110;
`endif
   assign op_adx      = inst[`PWORD_SIZE-1 -: 6] == 6'b100110;
   assign op_ldi      = inst[`PWORD_SIZE-1 -: 6] == 6'b100000;
   assign op_reti     = inst[`PWORD_SIZE-1 -: 6] == 6'b100011;
   assign op_adc      = inst[`PWORD_SIZE-1 -: 6] == 6'b100100;
   assign op_ads      = inst[`PWORD_SIZE-1 -: 6] == 6'b100101;
   assign op_tax      = inst[`PWORD_SIZE-1 -: 13] == 13'b1010000100000;
   assign op_taxu     = inst[`PWORD_SIZE-1 -: 13] == 13'b1010000100001;
   assign op_call     = inst[`PWORD_SIZE-1]       == 1'b0;
   assign op_ldx      = inst[`PWORD_SIZE-1 -: 12] == 12'b101000011000;
   assign op_addax    = inst[`PWORD_SIZE-1 -: 11] == 11'b10100001101 & inst[1:0] == 2'b00;
   assign op_addaxu   = inst[`PWORD_SIZE-1 -: 11] == 11'b10100001101 & inst[2:0] == 3'b001;
   assign op_subax    = inst[`PWORD_SIZE-1 -: 11] == 11'b10100001101 & inst[1:0] == 2'b10;
   assign op_subaxu   = inst[`PWORD_SIZE-1 -: 11] == 11'b10100001101 & inst[2:0] == 3'b011;
   assign op_call_ix  = inst[`PWORD_SIZE-1 -: 11] == 11'b10001010100;
   assign op_jmp_ix   = inst[`PWORD_SIZE-1 -: 11] == 11'b10001010101;
   assign op_cpi      = inst[`PWORD_SIZE-1 -: 6]  == 6'b101001;
   assign op_cmp      = inst[`PWORD_SIZE-1 -: 6]  == 6'b111010;
   assign op_if       = inst[`PWORD_SIZE-1 -: 8]  == 8'b10100010;
   assign op_swap     = inst[`PWORD_SIZE-1 -: 6]  == 6'b111011;
   assign op_swapi    = inst[`PWORD_SIZE-1 -: 6]  == 6'b110111;
   assign op_add      = inst[`PWORD_SIZE-1 -: 6]  == 6'b110000;
   assign op_sub      = inst[`PWORD_SIZE-1 -: 6]  == 6'b110010;
   assign op_and      = inst[`PWORD_SIZE-1 -: 6]  == 6'b110100;
   assign op_andi     = inst[`PWORD_SIZE-1 -: 6]  == 6'b110101;
   assign op_or       = inst[`PWORD_SIZE-1 -: 6]  == 6'b110110;
   assign op_xor      = inst[`PWORD_SIZE-1 -: 6]  == 6'b111000;
   assign op_ldax     = inst[`PWORD_SIZE-1 -: 6]  == 6'b111100;
   assign op_ldxx     = inst[`PWORD_SIZE-1 -: 7]  == 7'b1100110;
   assign op_stxx     = inst[`PWORD_SIZE-1 -: 7]  == 7'b1100111;
   assign op_btst     = inst[`PWORD_SIZE-1 -: 11] == 11'b10_1000_0001_0;
   assign op_sra      = inst[`PWORD_SIZE-1 -: 14] == 14'b10_1000_0101_1000;
   assign op_lra      = inst[`PWORD_SIZE-1 -: 14] == 14'b10_1000_0101_1001;
   assign op_ldirq    = inst[`PWORD_SIZE-1 -: 14] == 14'b10_1000_0100_1000;
   assign op_stirq    = inst[`PWORD_SIZE-1 -: 14] == 14'b10_1000_0100_1001;
   assign op_push_ix  = inst[`PWORD_SIZE-1 -: 14] == 14'b10_1000_0101_1010;
   assign op_pop_ix   = inst[`PWORD_SIZE-1 -: 14] == 14'b10_1000_0101_1011;
   assign op_lddiv    = inst[`PWORD_SIZE-1 -: 14] == 14'b10_1000_0101_1100;
   assign op_savec    = inst[`PWORD_SIZE-1 -: 14] == 14'b10_1000_0101_1110;
   assign op_restc    = inst[`PWORD_SIZE-1 -: 14] == 14'b10_1000_0101_1111;
   assign op_push_a   = inst[`PWORD_SIZE-1 -: 10] == 10'b10_1000_0010;
   assign op_pop_a    = inst[`PWORD_SIZE-1 -: 10] == 10'b10_1000_0011;
   assign op_mul      = WANT_MUL ? (inst[`PWORD_SIZE-1 -: 6] == 6'b110001) : 1'b0;
   assign op_mulu     = WANT_MUL ? (inst[`PWORD_SIZE-1 -: 6] == 6'b100001) : 1'b0;
   assign op_xchg_ra  = inst[`PWORD_SIZE-1 -: 14] == 14'b10001010110000;
   assign op_xchg_ia  = inst[`PWORD_SIZE-1 -: 14] == 14'b10001010110001;
   assign op_xchg_sp  = inst[`PWORD_SIZE-1 -: 14] == 14'b10001010110010;
   assign op_spix     = inst[`PWORD_SIZE-1 -: 14] == 14'b10001010110011;
   assign op_cpx_ra   = inst[`PWORD_SIZE-1 -: 14] == 14'b10001010110100;
   assign op_cpx_sp   = inst[`PWORD_SIZE-1 -: 14] == 14'b10001010110110;
   assign op_st       = inst[`PWORD_SIZE-1 -: 5]  == 5'b11111;
   assign op_sta      = op_st & inst[`PWORD_SIZE-6];
   assign op_lda      = inst[`PWORD_SIZE-1 -: 6]  == 6'b111101;
   assign op_ld_misc  = inst[`PWORD_SIZE-1 -: 6]  == 6'b101000;
   assign op_ldac     = inst[`PWORD_SIZE-1 -: 11] == 11'b10100001110;
   assign op_dcx      = inst[`PWORD_SIZE-1 -: 6]  == 6'b100111;
   assign op_inx      = inst[`PWORD_SIZE-1 -: 6]  == 6'b111001;
   assign op_txa      = inst[`PWORD_SIZE-1 -: 14] == 14'b10100000000100;
   assign op_txau     = inst[`PWORD_SIZE-1 -: 14] == 14'b10100000000110;
   assign op_shl      = inst[`PWORD_SIZE-1 -: 14] == 14'b10100000000000;
   assign op_shr      = inst[`PWORD_SIZE-1 -: 14] == 14'b10100000000001;
   assign op_ldc      = inst[`PWORD_SIZE-1 -: 13] == 13'b1010000000001;
   assign op_shl16    = inst[`PWORD_SIZE-1 -: 12] == 12'b10_1000_0000_10;
   assign op_shr16    = inst[`PWORD_SIZE-1 -: 12] == 12'b10_1000_0000_11;
   assign op_ldz      = inst[`PWORD_SIZE-1 -: 12] == 12'b10_1000_0001_10;
   assign op_notz     = inst[`PWORD_SIZE-1 -: 14] == 14'b10100000011101;
   assign op_eidi     = inst[`PWORD_SIZE-1 -: 14] == 14'b10100000011110;
   assign op_amode    = inst[`PWORD_SIZE-1 -: 13] == 13'b1010000101000;     // amode #m: 0xa140 | m
   assign op_ldamode  = inst[`PWORD_SIZE-1 -: 13] == 13'b1010000101001;     // ldamode: A <= {ie, amode}, 0xa148
`ifdef WANT_BF16
   assign op_tfa      = inst[`PWORD_SIZE-1 -: 15] == 15'b101000011110000;
   assign op_taf      = inst[`PWORD_SIZE-1 -: 15] == 15'b101000011110001;
   assign op_fmul     = inst[`PWORD_SIZE-1 -: 14] == 14'b10100001111001;
   assign op_fadd     = inst[`PWORD_SIZE-1 -: 14] == 14'b10100001111010;
   assign op_fneg     = inst[`PWORD_SIZE-1 -: 14] == 14'b10100001111011;
   assign op_fswap    = inst[`PWORD_SIZE-1 -: 14] == 14'b10100001111100;
   assign op_fcmp     = inst[`PWORD_SIZE-1 -: 14] == 14'b10100001111101;
   assign op_fdiv     = inst[`PWORD_SIZE-1 -: 14] == 14'b10100001111110;
   assign op_itof     = inst[`PWORD_SIZE-1 -: 16] == 16'b1010001100100000;
   assign op_ftoi     = inst[`PWORD_SIZE-1 -: 16] == 16'b1010001100100001;
   assign op_fclr     = inst[`PWORD_SIZE-1 -: 16] == 16'b1010001100100010;
`endif
   assign op_brk      = WANT_DBG ? inst[`PWORD_SIZE-1 -: 14] == 14'b10100000011111 : 1'b0;
   assign op_div      = WANT_DIV ? inst[`PWORD_SIZE-1 -: 12] == 12'b10_1000_110000 : 1'b0;
   assign op_rem      = WANT_DIV ? inst[`PWORD_SIZE-1 -: 12] == 12'b10_1000_110001 : 1'b0;
   assign op_any_div  = op_div_r | op_rem_r;
   assign op_div_start = ((op_any_div & inst[0] & cond[0]) | div_stage_two | rem_stage_two) & exec_state & d_ok;
   assign div_divisor  = {div_args[0] ? (amode[1] ? {8{acc[7]}} : 8'h00) : d_i, acc};
   assign div_dividend = {div_args[1] ? (amode[1] ? {8{ix[7]}}  : 8'h00) : ra[7:0], ix[7:0]};

   assign pc_inc   = pc + {{(PC_BITS-1){1'b0}}, 1'b1};
   assign pc_rel   = pc + {{(PC_BITS-11){inst[10]}}, inst[10:0]};
   assign ix_sum   = ix + {{(PC_BITS-10){inst[9]}}, inst[9:0]};
   assign ix_addr  = ix + {{(PC_BITS-9){1'b0}}, inst[8:0]};
   // The stack: push a / sra / push ix write at SP - 1 and SP is decremented
   // as the write completes (the delayed decrement below), pop a / lra /
   // pop ix read at SP and increment it after, so SP is the address of the
   // byte on top and 0(sp) the top of a frame.  TT07 wrote at SP and read at
   // SP + 1 (SP one below the top, the top at 1(sp)); the toolchain's --rev2
   // builds are laid out for this one.  The two bytes of sra / push ix keep
   // their order: the low byte first (at SP - 1), then the high byte with
   // the condition bit (at SP - 2, the lower address).
   assign sp_adder = (op_sra_r | op_push_a_r | op_push_ix_r) ? {D_BITS{1'b1}} :
                     (((op_ldxx_r | op_stxx_r ) & stage_two) |
                        lddiv_stage_two | div_stage_two  |
                        rem_stage_two)                       ? {{(D_BITS-D_STCK){1'b0}}, inst[D_STCK-1:0]} :
                     ((op_ldxx_r | op_stxx_r) & !stage_two)  ? {{(D_BITS-D_STCK){1'b0}}, inst[D_STCK-1:0]}+1 :
                     (op_shl16_r | op_shr16_r)               ? {{(D_BITS-2){1'b0}}, inst[1:0]} :
                     (op_lra_r | op_pop_a_r | op_pop_ix_r)   ? {D_BITS{1'b0}} :
                                                               {{(D_BITS-D_INST){inst[9]}}, inst[9:0]};
   assign sp_sum   = sp + sp_adder;
   assign sp_addr  = sp + {{(D_BITS-D_STCK){1'b0}}, inst[D_STCK-1:0]};

   // The adder: a real carry-in (TT07 folded it into the 8-bit operand, so
   // adc #0xff with C set added 0, and sub / cmp of a zero operand borrowed).
   // add has none by design; sub is A + ~M + !C (A - M - C); cmp / cpi are
   // A + ~M + 1, C the borrow.
   reg                        acc_cin;
   always @*
   begin
      acc_adder = d_i;
      acc_cin   = 1'b0;
      case (1'b1)
         op_adc_r:   begin acc_adder = inst[7:0];  acc_cin = cflag;  end   // adc
         op_cpi_r:   begin acc_adder = ~inst[7:0]; acc_cin = 1'b1;   end   // cpi
         op_sub_r:   begin acc_adder = ~d_i;       acc_cin = ~cflag; end   // sub (sbb)
         op_cmp_r:   begin acc_adder = ~d_i;       acc_cin = 1'b1;   end   // cmp
      endcase
   end
   // ACC math
   assign acc_sum = {1'b0, acc} + {1'b0, acc_adder} + {8'h0, acc_cin};
   assign c_cpi = ~acc_sum[8];

   assign i_addr = pc;
   assign i_fetch = fetch_state  & !stop;
   assign inst_o = dbg_di[`PWORD_SIZE-1 :0];
   assign inst_we = stop && dbg_a == 8'hf && dbg_we == 1'b1;
   assign d_o_shr_val = (amode[0] & cflag) | (amode[1] & d_i[7]);

   assign   non_acc_d_o = op_sra_r | op_push_ix_r | op_stxx_r | op_dcx_r | op_inx_r | op_shr16_r | op_shl16_r;
   always @*
   begin
      if (dbg_d_access)
         d_o = dbg_d_o;
      else
      begin
         if (stop && !d_we_r)               // not while a store is still landing
            d_o = dbg_di[7:0];
         else if (non_acc_d_o)
         begin
            d_o = 8'hxx;
            case (1'b1)
            op_sra_r & stage_two:           d_o = {ra_cond,ra[(PC_BITS-1):8]};
            op_sra_r & ~stage_two:          d_o = ra[7:0];
            op_push_ix_r & stage_two:       d_o = {ix_cond,ix[(PC_BITS-1):8]};
            op_push_ix_r & ~stage_two:      d_o = ix[7:0];
            op_stxx_r & ~stage_two:         d_o = {ix_cond,ix[(PC_BITS-1):8]};
            op_stxx_r & stage_two:          d_o = ix[7:0];
            op_dcx_r:                       d_o = d_i-8'h1;
            op_inx_r:                       d_o = d_i+8'h1;
            op_shr16_r:                     d_o = {d_o_shr_val, d_i[7:1]};
            op_shl16_r:                     d_o = {d_i[6:0], acc[7]};
            default:                        d_o = 8'hxx;
            endcase
         end
         else
            d_o = acc;
      end
   end

   // add read conditions to d_valid
   assign d_valid    = (d_we & ~d_periph) | (d_valid_rd & (exec_state | stg2_state) && !ldx_stage_two) |
                       (dbg_d_access && !dbg_d_periph) ;
   assign d_ok       = d_ready || !d_valid;
   assign d_we       = dbg_d_access ? dbg_we : d_we_r;
   assign d_periph   = ((op_sta_r | op_lda_r | op_swapi_r) & inst[9] & !dbg_d_access) | dbg_d_periph;
   assign d_valid_rd = op_mul_r | op_mulu_r | op_pop_ix_r | div_stage_two | rem_stage_two | //(op_any_div & inst[0] == 1'b0) |
                       op_adc_r | op_dcx_r | op_shl16_r | op_shr16_r | op_pop_a_r |
                       lddiv_stage_two | op_lra_r | op_add_r | op_sub_r | op_cmp_r | op_dcx_r | op_inx_r |
                       op_ldxx_r | op_and_r | op_or_r | (op_swapi_r & !inst[9] & !dbg_d_access) | op_xor_r | op_swap_r |
                       (op_lda_r & !inst[9] & !dbg_d_access) | op_ldax_r;
   // a debugger RAM access is ready when the cache says so AND the debug
   // block's own delay has passed: with the cache off d_ready is always 1,
   // and TT07 answered in the first clock with RAM[IX] still on the bus
   assign dbg_ready  = (dbg_d_access & !d_periph) ? (d_ready_r & dbg_ready_c) : dbg_ready_c;
   assign d_rd       = dbg_d_access ? dbg_d_rd : d_periph & cond[0] & exec_state;
   assign dbg_inc    = (dbg_we | dbg_rd) && dbg_a == 8'hf;
   // swap n(sp) takes the sp_addr path like every other n(sp) operand (TT07
   // sent it through the ads adder, which sign-extended the select bit: -512)
   assign sp_sum_op  = op_sra_r | op_lra_r | op_ads_r | op_pop_a_r | op_push_a_r |
                       op_push_ix_r | op_pop_ix_r | op_stxx_r | op_ldxx_r | op_shl16_r | op_shr16_r | div_stage_two |
                       rem_stage_two | lddiv_stage_two;
   assign d_addr_imm = inst[`PWORD_SIZE-6] == 1'b1 && inst[`PWORD_SIZE-4] == 1'b1 &&
                       inst[`PWORD_SIZE-2] == 1'b1;
   // halted, the data address is IX (register 6 reads RAM[IX]) - but not
   // before a pending store has landed: a breakpoint on the instruction after
   // a store halts in the store's write clock, and TT07 then wrote the
   // debugger's last data byte to RAM[IX] and lost the store
   assign d_addr = dbg_d_access ? dbg_d_addr : (stop && !d_we_r) ? ix : d_addr_imm ? {{(D_BITS-D_STCK){1'b0}}, inst[D_STCK-1:0]} : (sp_sum_op) ? sp_sum :
                        inst[9] ? sp_addr : ix_addr;
   assign acc_mul = acc * d_i;
   assign acc_muls = $signed(acc) * $signed(d_i);

   // Create ACC misc load value
   wire   acc_shl_val;
   wire   acc_shr_val;

   assign acc_shl_val = amode[0] & cflag;
   assign acc_shr_val = (amode[0] & cflag) | (amode[1] & acc[7]);
   always @*
   begin
      acc_misc = 8'b0;
      acc_ld_misc = 1'b0;

      case (1'b1)
      op_shl_r:            {acc_ld_misc, acc_misc} = {1'b1, {acc[6:0], acc_shl_val}};       // shl
      op_shr_r:            {acc_ld_misc, acc_misc} = {1'b1, {acc_shr_val, acc[7:1]}};       // shr
      op_pop_a_r:          {acc_ld_misc, acc_misc} = {1'b1, d_i};                           // pop a
      op_txa_r:            {acc_ld_misc, acc_misc} = {1'b1, ix[7:0]};                       // txa
      op_txau_r:           {acc_ld_misc, acc_misc} = {1'b1, ix_cond, ix[(PC_BITS-1):8]};    // taxu
      op_div_r | op_rem_r: {acc_ld_misc, acc_misc} = {div_ready, div_result[7:0]};          // div,etc
      op_ldac_r:           {acc_ld_misc, acc_misc} = {1'b1, 7'h0, cond_load};               // ldac
      op_ldamode_r:        {acc_ld_misc, acc_misc} = {1'b1, 4'h0, ie, amode};                // ldamode
`ifdef WANT_BF16
      op_tfa_r:            if (inst[1] == 1'b0)
                            {acc_ld_misc, acc_misc} = {1'b1, f_half[inst[0]]};             // tfa
`endif
      endcase
   end

   // Create ACC load val
   always @*
   begin
      acc_load_val = {1'b0, 8'bx};

      if ((div_stage_two | rem_stage_two) & div_ready)
         acc_load_val = {1'b1, div_result[7:0]};
      else if (stop && dbg_we && dbg_a == 8'h1 && ~dbg_di[15])
         acc_load_val = {1'b1, dbg_di[7:0]};
      else
      case (1'b1)
      op_ldi_r:   acc_load_val = {1'b1, inst[7:0]};
      op_reti_r:  acc_load_val = {1'b1, inst[7:0]};
      op_adc_r:   acc_load_val = {1'b1, acc_sum[7:0]};
      op_add_r:   acc_load_val = {1'b1, acc_sum[7:0]};
      op_mul_r:   acc_load_val = {1'b1, amode[1] ? acc_muls[7:0] : acc_mul[7:0]};
      op_mulu_r:  acc_load_val = {1'b1, amode[1] ? acc_muls[15:8] : acc_mul[15:8]};
      op_sub_r:   acc_load_val = {1'b1, acc_sum[7:0]};
      op_and_r:   acc_load_val = {1'b1, acc & d_i};
      op_andi_r:  acc_load_val = {1'b1, acc & inst[7:0]};
      op_or_r:    acc_load_val = {1'b1, acc | d_i};
      op_xor_r:   acc_load_val = {1'b1, acc ^ d_i};
      op_lda_r || op_ldax_r:  acc_load_val = {1'b1, d_i};
      op_ld_misc_r:           if (acc_ld_misc) acc_load_val = {1'b1, acc_misc};  
      op_ldirq_r: acc_load_val = {1'b1, amode_isr, signed_inv_live_isr, cflag_save_isr, signed_inv_isr, zflag_isr, cflag_isr};
      endcase
   end

   // Create load_c signal
   assign c_load = op_ldi_r ||         // ldi #imm8
                   op_adc_r ||         // adc #imm8
                   op_add_r ||         // add a,[ix+#imm8]
                   op_sub_r ||         // sub a,[ix+#imm8]
                   op_cmp_r ||         // cmp a,[ix+#imm8]
                   op_cpi_r ||         // cpi a,#imm8
                   op_dcx_r ||         // dcx
                   op_inx_r ||         // inx
                   op_shl_r ||
                   op_shr_r ||
                   op_ldc_r ||
                   op_cpx_ra_r ||
                   op_cpx_sp_r ||      // cpx
                   op_restc_r ||       // Restore c
                   op_fcmp_r ||        // Floating point compare
                   op_fdiv_r;          // FP divide = TRUE if valid

   // Sign wires for facc and fx
   wire  s_facc;
   wire  s_fx;
   assign s_facc = facc[15];
   assign s_fx   = fx[inst[1:0]][15];

   // Create value to load to cflag
   always @*
   begin
      c_val = 1'bx;
      signed_valid = 1'b0;

      if (stop && dbg_we && dbg_a == 8'h1 && dbg_di[15])
         c_val = dbg_di[9];
      else
      case (1'b1)
      op_ldi_r:  c_val                 = 1'b0;                 // lda #imm8
      op_adc_r:  {signed_valid, c_val} = {1'b1, acc_sum[8]};   // adc #imm8
      op_add_r:  {signed_valid, c_val} = {1'b1, acc_sum[8]};   // add a,[ix+#imm8]
      op_sub_r:  {signed_valid, c_val} = {1'b1, ~acc_sum[8]};  // sub a,[ix+#imm8]
      op_cmp_r:  {signed_valid, c_val} = {1'b1, ~acc_sum[8]};  // cmp a,[ix+#imm8]
      op_dcx_r:  c_val                 = d_i == 8'h0;          // dcx
      op_inx_r:  c_val                 = d_i == 8'hFF;         // inx
      op_shl_r:  c_val                 = acc[7];
      op_shr_r:  c_val                 = acc[0];
      op_ldc_r:  c_val                 = inst[0];
      op_cpi_r:  {signed_valid, c_val} = {1'b1, c_cpi};          // cpi: the signed inversion too
      op_cpx_ra: c_val                 = ix < ra;
      op_cpx_sp: c_val                 = ix < sp[D_BITS-1:0];
      op_restc_r:c_val                 = cflag_save;
      ret_isr_r: c_val                 = cflag_isr;
      op_fdiv_r: c_val                 = fdiv_valid;
      op_fcmp_r:
            begin
               if ((~s_facc & s_fx)                   ||          // If facc positive and fx negative
                   (~s_facc && ~s_fx &&                           // Both positive and facc > fx
                    facc[14:0] > fx[inst[1:0]][14:0]) ||
                   (s_facc && s_fx &&                             // Both negative and facc < fx
                    facc[14:0] < fx[inst[1:0]][14:0]))
               begin
                  c_val = 1'b1;
               end
               else
                  c_val = 1'b0;
            end
      endcase
   end

   // =================================================
   // Implement the pre-decode to generate flops
   // to use during decode to simplify the timing
   // and routing
   // =================================================
   always @(posedge clk or negedge rst_async_n)
   begin
      if (~rst_async_n)
      begin
         jump_taken_r <= 1'b0;
         br_taken_r <= 1'b0;
         ret_taken_r <= 1'b0;
         ret_isr_r <= 1'b0;
         op_adx_r <= 1'b0;
         op_ldx_r <= 1'b0;
         op_addax_r <= 1'b0;
         op_addaxu_r <= 1'b0;
         op_subax_r <= 1'b0;
         op_subaxu_r <= 1'b0;
         op_ldi_r <= 1'b0;
         op_reti_r <= 1'b0;
         op_adc_r <= 1'b0;
         op_ads_r <= 1'b0;
         op_tax_r <= 1'b0;
         op_taxu_r <= 1'b0;
         op_call_ix_r <= 1'b0;
         op_jmp_ix_r <= 1'b0;
         op_call_r <= 1'b0;
         op_xchg_sp_r <= 1'b0;
         op_xchg_ra_r <= 1'b0;
         op_xchg_ia_r <= 1'b0;
         op_cpx_ra_r <= 1'b0;
         op_cpx_sp_r <= 1'b0;
         op_spix_r <= 1'b0;
         op_push_a_r <= 1'b0;
         op_pop_a_r <= 1'b0;
         op_lddiv_r <= 1'b0;
         op_savec_r <= 1'b0;
         op_restc_r <= 1'b0;
         op_mul_r <= 1'b0;
         op_mulu_r <= 1'b0;
         op_cpi_r <= 1'b0;
         op_cmp_r <= 1'b0;
         op_if_r <= 1'b0;
         op_btst_r <= 1'b0;
         op_swap_r <= 1'b0;
         op_swapi_r <= 1'b0;
         op_sra_r <= 1'b0;
         op_lra_r <= 1'b0;
         op_ldirq_r <= 1'b0;
         op_stirq_r <= 1'b0;
         op_push_ix_r <= 1'b0;
         op_pop_ix_r <= 1'b0;
         op_st_r <= 1'b0;
         op_sta_r <= 1'b0;
         op_lda_r <= 1'b0;
         op_ld_misc_r <= 1'b0;
         op_ldac_r <= 1'b0;
         op_dcx_r <= 1'b0;
         op_inx_r <= 1'b0;
         op_ldxx_r <= 1'b0;
         op_stxx_r <= 1'b0;
         op_txa_r <= 1'b0;
         op_txau_r <= 1'b0;
         op_shl_r <= 1'b0;
         op_shr_r <= 1'b0;
         op_ldc_r <= 1'b0;
         op_shl16_r <= 1'b0;
         op_shr16_r <= 1'b0;
         op_div_r <= 1'b0;
         op_div_start_r <= 1'b0;
         op_rem_r <= 1'b0;
         op_ldz_r <= 1'b0;
         op_brk_r <= 1'b0;
         op_eidi_r <= 1'b0;
         op_notz_r <= 1'b0;
         op_amode_r <= 1'b0;
         op_ldamode_r <= 1'b0;
         op_add_r <= 1'b0;
         op_sub_r <= 1'b0;
         op_and_r <= 1'b0;
         op_andi_r <= 1'b0;
         op_or_r <= 1'b0;
         op_xor_r <= 1'b0;
         op_ldax_r <= 1'b0;
`ifdef WANT_BF16
         op_tfa_r <= 1'b0;
         op_taf_r <= 1'b0;
         op_fmul_r <= 1'b0;
         op_fadd_r <= 1'b0;
         op_fneg_r <= 1'b0;
         op_fswap_r <= 1'b0;
         op_itof_r <= 1'b0;
         op_ftoi_r <= 1'b0;
         op_fclr_r <= 1'b0;
         op_fcmp_r <= 1'b0;
`endif
      end
      else
      begin
         jump_taken_r <= jump_taken;
         br_taken_r <= br_taken;
         ret_taken_r <= ret_taken;
         ret_isr_r <= ret_isr;
         op_adx_r <= op_adx;
         op_ldx_r <= op_ldx;
         op_addax_r <= op_addax;
         op_addaxu_r <= op_addaxu;
         op_subax_r <= op_subax;
         op_subaxu_r <= op_subaxu;
         op_ldi_r <= op_ldi;
         op_reti_r <= op_reti;
         op_adc_r <= op_adc;
         op_ads_r <= op_ads;
         op_tax_r <= op_tax;
         op_taxu_r <= op_taxu;
         op_call_ix_r <= op_call_ix;
         op_jmp_ix_r <= op_jmp_ix;
         op_call_r <= op_call;
         op_xchg_sp_r <= op_xchg_sp;
         op_xchg_ra_r <= op_xchg_ra;
         op_xchg_ia_r <= op_xchg_ia;
         op_cpx_ra_r <= op_cpx_ra;
         op_cpx_sp_r <= op_cpx_sp;
         op_spix_r <= op_spix;
         op_push_a_r <= op_push_a;
         op_pop_a_r <= op_pop_a;
         op_lddiv_r <= op_lddiv;
         op_savec_r <= op_savec;
         op_restc_r <= op_restc;
         op_mul_r <= op_mul;
         op_mulu_r <= op_mulu;
         op_cpi_r <= op_cpi;
         op_cmp_r <= op_cmp;
         op_if_r <= op_if;
         op_btst_r <= op_btst;
         op_swap_r <= op_swap;
         op_swapi_r <= op_swapi;
         op_sra_r <= op_sra;
         op_lra_r <= op_lra;
         op_ldirq_r <= op_ldirq;
         op_stirq_r <= op_stirq;
         op_push_ix_r <= op_push_ix;
         op_pop_ix_r <= op_pop_ix;
         op_st_r <= op_st;
         op_sta_r <= op_sta;
         op_lda_r <= op_lda;
         op_ld_misc_r <= op_ld_misc;
         op_ldac_r <= op_ldac;
         op_dcx_r <= op_dcx;
         op_inx_r <= op_inx;
         op_ldxx_r <= op_ldxx;
         op_stxx_r <= op_stxx;
         op_txa_r <= op_txa;
         op_txau_r <= op_txau;
         op_shl_r <= op_shl;
         op_shr_r <= op_shr;
         op_ldc_r <= op_ldc;
         op_shl16_r <= op_shl16;
         op_shr16_r <= op_shr16;
         op_div_r <= op_div;
         op_div_start_r <= op_div_start;
         op_rem_r <= op_rem;
         op_ldz_r <= op_ldz;
         op_brk_r <= op_brk;
         op_eidi_r <= op_eidi;
         op_notz_r <= op_notz;
         op_amode_r <= op_amode;
         op_ldamode_r <= op_ldamode;
         op_add_r <= op_add;
         op_sub_r <= op_sub;
         op_and_r <= op_and;
         op_andi_r <= op_andi;
         op_or_r <= op_or;
         op_xor_r <= op_xor;
         op_ldax_r <= op_ldax;
`ifdef WANT_BF16
         op_tfa_r <= op_tfa;
         op_taf_r <= op_taf;
         op_fmul_r <= op_fmul;
         op_fdiv_r <= op_fdiv;
         op_fadd_r <= op_fadd;
         op_fneg_r <= op_fneg;
         op_fswap_r <= op_fswap;
         op_itof_r <= op_itof;
         op_ftoi_r <= op_ftoi;
         op_fclr_r <= op_fclr;
         op_fcmp_r <= op_fcmp;
`endif
      end
   end

   // =================================================
   // Implement Return Address (RA) logic
   // =================================================
   always @*
   begin
      ra_val      = ra;
      ra_cond_val = ra_cond;
      ra_load     = 1'b0;

      case (1'b1)
      // Fetch state
      fetch_state:
         if (stop && dbg_we && dbg_a == 8'h4)
         begin
            ra_load = 1'b1;
            {ra_cond_val, ra_val} = dbg_di[PC_BITS:0];
         end

      // Decode state
      decode_state:
         // Test for JC, JZ, CC or CZ opcodes
         if (cond[0] && !isr_jump && (op_call_ix_r || op_call_r))
         begin
            // Save the Return Address
            ra_load = 1'b1;
            {ra_cond_val, ra_val} = {cond[1], pc_inc};
         end

      // Execute and Increment PC
      exec_state:
         // Test for xchg_ra opcode
         if (cond[0] & op_xchg_ra_r)
         begin
            ra_load = 1'b1;
            {ra_cond_val, ra_val} = {ix_cond, ix};
         end
         else if (lddiv_stage_two & d_ok)
         begin
            ra_load = 1'b1;
            ra_val[7:0] = d_i;
         end

      // Process 2-stage opcode
      stg2_state:
         // Perform lra to save back to ra
         if (op_lra_r & d_ok)
         begin
            ra_load = 1'b1;
            if (stage_two)
               ra_val[7:0] = d_i;
            else
               {ra_cond_val, ra_val[(PC_BITS-1):8]} = d_i[PC_BITS-8:0];
         end
      endcase
   end

   // =================================================
   // Implement PC and state control
   // =================================================
   always @(posedge clk or negedge rst_async_n)
   begin
      if (!rst_async_n)
      begin
         inst_r <= 'h0;
         pc <= {PC_BITS{1'b0}};
         ia <= {PC_BITS{1'b0}};
         isr_jump <= 1'b0;
         ie <= 1'b0;
         state <= 3'h0;
         stage_two <= 1'b0;
         d_we_r <= 1'b0;
         dbg_inc_r <= 1'b0;
         d_ready_r <= 1'b0;
         cflag_isr <= 1'b0;
         zflag_isr <= 1'b0;
         signed_inv_isr <= 1'b0;
         cflag_save_isr <= 1'b0;
         signed_inv_live_isr <= 1'b0;
         amode_isr <= 3'h1;
      end
      else
      begin
         // Register the instruction
         if (inst_ready & !d_we_r)
            inst_r <= inst_i;

         d_ready_r <= d_ready;

         if (reset)
         begin
            inst_r <= 'h0;
            pc <= {PC_BITS{1'b0}};
            ia <= {PC_BITS{1'b0}};
            isr_jump <= 1'b0;
            state <= 3'h0;
            stage_two <= 1'b0;
            d_we_r <= 1'b0;
            dbg_inc_r <= 1'b0;
            cflag_isr <= 1'b0;
            zflag_isr <= 1'b0;
            signed_inv_isr <= 1'b0;
            cflag_save_isr <= 1'b0;
            signed_inv_live_isr <= 1'b0;
            amode_isr <= 3'h1;
         end
         else
         case (1'b1)
         // Fetch state waiting for the Inst SRAM to deliver data
         // or for a delayed write to DATA SRAM to complete
         fetch_state:
            begin
               if (d_we_r)
               begin
                  if (d_ok)
                     d_we_r <= 1'b0;
               end
               else
               begin
                  dbg_inc_r <= dbg_inc;
                  if (!stop && inst_ready)
                     state <= 3'h1;    // Switch to decode state
                  else if (dbg_we && dbg_a == 8'h2)
                     pc <= dbg_di[PC_BITS-1:0];
                  else if (dbg_inc_r && !dbg_inc)
                     pc <= pc + 1;
               end
            end

         // Pre-decode state
         predec_state:
            if (stop)
               state <= 3'h0;
            else
               state <= 3'h2;

         // Decode state
         decode_state:
            // Test for JC, JZ, CC or CZ opcodes
            if (cond[0] && (jump_taken_r || ret_taken_r || ret_isr_r || br_taken_r || op_call_ix_r || op_jmp_ix_r))
            begin
               case (1'b1)
                  jump_taken_r:             pc <= inst[PC_BITS-1:0];
                  ret_taken_r:              pc <= ra;
                  ret_isr_r:                pc <= ia;
                  br_taken_r:               pc <= pc_rel;
                  op_call_ix_r|op_jmp_ix_r: pc <= ix;
               endcase

               // Possibly clear isr_jump
               if (jump_taken_r || br_taken_r)
                  isr_jump <= 1'b0;

               // For RET_ISR, we re-enable the ie bit
               if (ret_isr_r)
                  ie <= 1'b1;

               // Switch to fetch state
               state <= 3'h0;
            end

            // brk: halt here (the debugger's resume or step runs it as a nop)
            else if (cond[0] && op_brk_r && !cont_q)
               state <= 3'h0;

            // Else execute the opcode (exec state)
            else
               state <= 3'h3;

         // Execute and Increment PC
         exec_state:
            begin
               if (d_ok)
               begin
                  // Test for 2-stage operations
                  if (stg2_next)
                  begin
                     // Go to state 4
                     state <= 3'h4;
                  end
                  else
                  begin
                     if (irq_pending)
                     begin
                        // The interrupt return address is the next PC
                        ia <= pc_inc;
                        isr_jump <= 1'b1;
                        ie <= 1'b0;
                        // the shadows take the state the interrupted instruction
                        // leaves behind - its own flag write lands in this clock
                        // (TT07 shadowed the values before it: after ldc #1 the
                        // carry came back clear)
                        cflag_isr <= cflag_load ? c_val : cflag;
                        zflag_isr <= zflag_load ? zflag_val : zflag;
                        signed_inv_isr <= (op_savec_r & cond[0]) ? signed_inversion : signed_inv_save;
                        cflag_save_isr <= (op_savec_r & cond[0]) ? cflag : cflag_save;
                        signed_inv_live_isr <= cflag_load ? signed_inv_val : signed_inversion;
                        amode_isr <= (op_amode_r & cond[0]) ? inst[2:0] : amode;
                        casez (int_i & int_en)
                        8'b???????1: pc <= PC_BITS'(1);
                        8'b??????10: pc <= PC_BITS'(2);
                        8'b?????100: pc <= PC_BITS'(3);
                        8'b????1000: pc <= PC_BITS'(4);
                        8'b???10000: pc <= PC_BITS'(5);
                        8'b??100000: pc <= PC_BITS'(6);
                        8'b?1000000: pc <= PC_BITS'(7);
                        8'b10000000: pc <= PC_BITS'(8);
                        default:     pc <= PC_BITS'(9);
                        endcase
                     end
                     else
                     begin
                        // Just increment the PC
                        pc <= pc_inc;

                        // Test for xchg_ia
                        if (cond[0] && op_xchg_ia_r)
                           ia <= ix;

                        // Test for EI/DI
                        if (cond[0] && op_eidi_r)
                           ie <= inst[0];

                        // Test for load of zflag_isr / cflag_isr
                        if (cond[0] && op_stirq_r)
                        begin
                           cflag_isr <= acc[0];
                           zflag_isr <= acc[1];
                           signed_inv_isr <= acc[2];
                           cflag_save_isr <= acc[3];
                           signed_inv_live_isr <= acc[4];
                           amode_isr <= acc[7:5];
                        end
                     end
                     state <= 3'h0;
                  end
               end

               // Test for stax ix+imm8 operation or swap a,[ix+imm8]: the write
               // starts once the read side is done (d_ok) - TT07 raised d_we
               // while a read-modify-write was still waiting on a cache miss,
               // and the first write went out with stale data
               if (d_ok && cond[0] && (op_st_r || op_swap_r || op_swapi_r || op_sra_r || op_push_a_r ||
                   op_dcx_r || op_inx_r || op_push_ix_r || op_stxx_r || op_shl16_r | op_shr16_r))
               begin
                  d_we_r <= 1'b1;
               end
            end

         // Process 2-stage opcode
         stg2_state:
            begin
               // Process the stage number and state
               if (stage_two)
               begin
                  if (d_ok)
                  begin
                     // Finished with 2-stage opcode.  Go fetch next instruction
                     pc <= pc_inc;
                     state <= 3'h0;
                     stage_two <= 1'b0;

                     // Drive WE low
                     d_we_r <= 1'b0;
                  end
               end
               else
               begin
                  if (!op_any_div & !div_stage_two & !rem_stage_two &
                      !op_fops & !op_fdiv_r)
                  begin
                     if (d_ok)
                     begin
                        // Back to execute stage to process 2nd stage
                        state <= 3'h3;
                        stage_two <= 1'b1;

                        // Drive WE low
                        d_we_r <= 1'b0;
                     end
                  end
                  else
                  begin
                     // Wait for the div to be ready
                     if (div_ready | op_fops | (op_fdiv_r & fdiv_ready))
                     begin
                        if (d_ok)
                        begin
                           pc <= pc_inc;
                           state <= 3'h0;
                        end

                        // the result stays in A and RA: no memory write (TT07's
                        // high-byte store never landed and the one-word forms
                        // wrote A to a stray address)
                     end
                  end
               end
            end
         endcase
      end
   end

   wire  cflag_signed = (inst[5] & signed_inversion) ? ~cflag : cflag;
   always @(inst[2:0], zflag, cflag, cflag_signed)
   begin
      cond_load = 1'bx;
      case (inst[2:0])
      3'h0: cond_load = zflag;                  // acc EQ  cmp
      3'h1: cond_load = ~zflag;                 // acc NE  cmp
      3'h2: cond_load = ~cflag;                 // NC
      3'h3: cond_load = cflag;                  // C
      3'h4: cond_load = ~cflag_signed & ~zflag; // acc GT  cmp
      3'h5: cond_load = cflag_signed & ~zflag;  // acc LT  cmp
      3'h6: cond_load = ~cflag_signed | zflag;  // acc GTE cmp
      3'h7: cond_load = cflag_signed | zflag;   // acc LTE cmp
      endcase
   end

   // =================================================
   // Implement the conditional execution registers
   // =================================================
   always @(posedge clk)
   begin
      if (!rst_n || reset)
         cond <= 2'h3;
      else
      begin
         if (d_ok)
         begin
            if (op_if_r & exec_state)
            begin
               case (inst[4:3])
               2'h0: // IF
                  begin
                     cond[0] <= cond_load;
                     cond[1] <= 1'b1;
                  end
               2'h1: // IFTT
                  begin
                     cond[0] <= cond_load;
                     cond[1] <= cond_load;
                  end
               2'h2: // IFTE
                  begin
                     cond[0] <= cond_load;
                     cond[1] <= ~cond_load;
                  end
               default: // IF
                  begin
                     cond[0] <= cond_load;
                     cond[1] <= 1'b1;
                  end
              endcase 
            end
            else if (cond[0] && decode_state &&  (jump_taken_r || br_taken_r || op_call_ix_r || op_jmp_ix_r))
               // Set both cond bits to 1 on any branch
               cond <= 2'h3;
            else if (cond[0] && decode_state && ret_taken_r)
            begin
               cond[1] <= 1'b1;
               cond[0] <= ra_cond;     // Pop condition code from ra
            end
            else if (cond[0] && decode_state && ret_isr_r)
               cond <= 2'h3;           // an interrupt is only taken with cond == 11
            else if (exec_state & cond[0] & (op_ldx_r | op_lddiv_r | (op_any_div & inst[0] == 1'b0)))
               cond[0] <= 1'b0;
            else if ((exec_state & (~(op_sra_r | op_lra_r | op_push_ix_r | op_pop_ix_r) | ldx_stage_two |
                        lddiv_stage_two | div_stage_two | rem_stage_two)) ||
                     (stg2_state && stage_two == 1'b1))
            begin
               cond[1] <= 1'b1;
               cond[0] <= cond[1];
            end
         end
         else if (stop && dbg_we && dbg_a == 8'h1 && dbg_di[15])
            cond <= dbg_di[11:10];
      end
   end

   // =================================================
   // Implement IX / ix_cond load logic
   // =================================================
   always @*
   begin
      ix_cond_val = ix_cond;
      ix_val      = ix;
      ix_load     = 1'b0;

      if (reset)
      begin
         {ix_cond_val, ix_val} = {1'b0, {PC_BITS{1'b0}}};
         ix_load = 1'b1;
      end
      else if (exec_state && cond[0])
      begin
         // Implement IX
         if ((op_adx_r | op_tax_r | op_taxu_r | op_xchg_sp_r | op_xchg_ra_r | op_spix_r | op_xchg_ia_r |
             op_addax_r | op_addaxu_r | op_subax_r | op_subaxu_r | op_lddiv_r) & d_ok)
         begin
            ix_load = 1'b1;
            case (1'b1)
               op_adx_r:                 {ix_cond_val, ix_val} = {1'b1, ix_sum};
               op_xchg_sp_r | op_spix_r: {ix_cond_val, ix_val} = {1'b1, sp};
               op_xchg_ra_r:             {ix_cond_val, ix_val} = {ra_cond, ra};
               op_xchg_ia_r:             {ix_cond_val, ix_val} = {1'b1, ia};
               op_tax_r | op_lddiv_r:    ix_val[7:0]       = acc;
               op_taxu_r:                {ix_cond_val, ix_val[PC_BITS-1:8]} = acc[PC_BITS-8:0];
               op_addax_r:               {ix_cond_val, ix_val} = {1'b1, ix + {{(PC_BITS-9){1'b0}},inst[2] & cflag, acc}};
               op_addaxu_r:              {ix_cond_val, ix_val[PC_BITS-1:8]} = {1'b1, ix[PC_BITS-1:8] + acc[PC_BITS-9:0]};
               op_subax_r:               {ix_cond_val, ix_val} = {1'b1, ix - {{(PC_BITS-9){1'b0}}, inst[2] & cflag, acc}};
               op_subaxu_r:              {ix_cond_val, ix_val[PC_BITS-1:8]} = {1'b1, ix[PC_BITS-1:8] - acc[PC_BITS-9:0]};
            endcase
         end
      end
      else if (exec_state & ldx_stage_two)
      begin
         ix_load = 1'b1;
         {ix_cond_val, ix_val} = {1'b1, inst[(PC_BITS-1):0]};
      end
      else if (stg2_state || delayed_sp_dec)
      begin
         // Perform pop IX
         if ((op_pop_ix_r | op_ldxx_r) & d_ok)
         begin
            ix_load = 1'b1;
            if (stage_two)
               ix_val[7:0] = d_i;
            else
               {ix_cond_val, ix_val[(PC_BITS-1):8]} = d_i[PC_BITS-8:0];
         end
      end
      else if (decode_state && cond[0] && op_call_ix_r)
      begin
         ix_load = 1'b1;
         {ix_cond_val, ix_val} = {cond[1], ix + {{(PC_BITS-1){1'b0}}, 1'b1}};
      end
      else if (stop && dbg_we && dbg_a == 8'h5)
      begin
         ix_load = 1'b1;
         {ix_cond_val, ix_val} = dbg_di[PC_BITS:0];
      end
   end

   // =================================================
   // Implement logic for ldx_stage_two
   // =================================================
   reg ldx_stage_two_val;
   reg ldx_stage_two_load;
   always @*
   begin
      ldx_stage_two_load = 0;
      ldx_stage_two_val = 1'bx;
      if (reset)
      begin
         ldx_stage_two_load = 1'b1;
         ldx_stage_two_val = 1'b0;
      end
      else
      begin
          // Implement IX load
         if (exec_state && cond[0] && op_ldx_r)
         begin
            ldx_stage_two_val = 1'b1;
            ldx_stage_two_load = 1'b1;
         end
         else if (exec_state & ldx_stage_two)
         begin
            ldx_stage_two_val = 1'b0;
            ldx_stage_two_load = 1'b1;
         end
      end
   end

   // =================================================
   // Implement logic for lddiv_stage_two and div_stage_two
   // =================================================
   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         lddiv_stage_two <= 1'b0;
         div_stage_two <= 1'b0;
         rem_stage_two <= 1'b0;
         div_args      <= 2'h0;
      end
      else
      begin
         // lddiv_stage_two
         if (reset || (exec_state & lddiv_stage_two & d_ok))
            lddiv_stage_two <= 1'b0;
         else if (exec_state && cond[0] && op_lddiv_r)
            lddiv_stage_two <= 1'b1;

         // div_stage_two
         if (reset || (div_stage_two & div_ready))
            div_stage_two <= 1'b0;
         else if (exec_state && cond[0] && op_div_r & inst[0] == 1'b0)
            div_stage_two <= 1'b1;

         // rem_stage_two
         if (reset || (rem_stage_two & div_ready ))
            rem_stage_two <= 1'b0;
         else if (exec_state && cond[0] && op_rem_r & inst[0] == 1'b0)
            rem_stage_two <= 1'b1;

         // Save div args
         if (decode_state && cond[0] && op_any_div)
            div_args <= inst[1:0];
      end
   end

   // =================================================
   // Implement IX and SP registers
   // =================================================
   always @(posedge clk)
   begin
      if (!rst_n || reset)
      begin
         sp      <= {D_BITS{1'b1}};       // Stack defaults to high memory
         delayed_sp_dec <= 1'b0;
      end
      else
      begin
         if (exec_state && cond[0])
         begin
            // Implement SP
            if ((op_xchg_sp_r | op_ads_r | op_push_a_r | op_pop_a_r) & d_ok)
            case (1'b1)
               op_ads_r:     sp <= sp_sum;
               op_xchg_sp_r: sp <= ix[D_BITS-1:0];
               op_pop_a_r:   sp <= sp + {{(D_BITS-1){1'b0}}, 1'b1};
            endcase

            if (op_push_a_r)
               delayed_sp_dec <= 1'b1;
         end
         else if (stg2_state || delayed_sp_dec)
         begin
            if (d_ok)
            begin
               if (op_sra_r | op_push_ix_r | delayed_sp_dec)
                  sp <= sp - {{(D_BITS-1){1'b0}}, 1'h1};
               else if (op_lra_r | op_pop_ix_r)
                  sp <= sp + {{(D_BITS-1){1'b0}}, 1'h1};

               delayed_sp_dec <= 1'b0;
            end
         end
         else if (stop && dbg_we && dbg_a == 8'h3)
            sp <= dbg_di[D_BITS-1:0];
      end
   end

   // =================================================
   // Implement the acc_delayed_val logic
   // =================================================
   always @*
   begin
      acc_delayed_val_load = 1'b0;
      if (exec_state && (op_swap_r | op_swapi_r | op_shl16_r | op_shr16_r) && cond[0])
         acc_delayed_val_load = 1'b1;

      if (op_swap_r | op_swapi_r)
         acc_delayed_val_val = d_i;
      else if (op_shl16_r)
         acc_delayed_val_val = {acc[6:0], acc_shl_val};
      else
         acc_delayed_val_val = {d_i[0], acc[7:1]};
   end

   // =================================================
   // Implement the accumulator
   // =================================================
   always @(posedge clk)
      if (!rst_n || reset)
      begin
         acc <= 8'h0;
         acc_delayed_load <= 1'b0;
         acc_delayed_val  <= 8'h0;
         amode <= 3'h1;
      end
      else
      begin
         if (d_ok)
         begin
            // Load the accumulator (test for ret # opcode since RET doesn't go to exec_state)
            // ret #imm8 loads A in the decode state (it never reaches exec);
            // TT07 kept loading through the fetch of the return, when inst
            // was already the instruction at the return address
            if ((exec_state || (op_reti_r && decode_state)) && cond[0] && acc_load_val[8])
               acc <= acc_load_val[7:0];
            else if (stg2_state && div_ready)
               acc <= acc_load_val[7:0];
            else if (acc_delayed_load)
               acc <= acc_delayed_val;

            // Test for reset
            if (reset)
               acc_delayed_load <= 1'b0;

            // For swap to memory, loading acc must be delayed one cycle
            else if (exec_state && (op_swap_r | op_swapi_r | op_shl16_r | op_shr16_r) && cond[0])
               acc_delayed_load <= 1'b1;
            else
               acc_delayed_load <= 1'b0;

            if (acc_delayed_val_load)
               acc_delayed_val <= acc_delayed_val_val;
         end

         // Implement amode register (rets restores the mode interrupted)
         if (reset)
            amode <= 3'h1;
         else if (exec_state && cond[0] && op_amode_r)
            amode <= inst[2:0];
         else if (decode_state && cond[0] && ret_isr_r)
            amode <= amode_isr;
         else if (stop && dbg_we && dbg_a == 8'h1 && dbg_di[15])
            amode <= dbg_di[14:12];
      end

   // =================================================
   // Logic for signed_inversion for signed compare
   // =================================================
   assign signed_inv_val = (decode_state & ret_isr_r) ? signed_inv_live_isr :
                           op_restc ?  signed_inv_save :  
                           signed_valid ? (acc[7] ^ (inst[`PWORD_SIZE-1 -: 6] == 6'b101001 ?
                                          inst[7] : d_i[7])) : 1'b0;

   // =================================================
   // Implement the zflag logic
   // =================================================
   always @*
   begin
      zflag_load = 1'b0;
      zflag_val  = zflag;
      if (exec_state && cond[0])
      begin
         if (reset)
            {zflag_load, zflag_val} = {1'b1, 1'b0};
         else if (d_ok)
            case (1'b1)
               acc_load_val[8]:     {zflag_load, zflag_val} = {1'b1, acc_load_val[7:0] == 8'h00};
               op_btst_r:             {zflag_load, zflag_val} = {1'b1, acc[inst[2:0]]};
               op_cpi_r:              {zflag_load, zflag_val} = {1'b1, acc == inst[7:0]};
               op_cmp_r:              {zflag_load, zflag_val} = {1'b1, acc == d_i};
               op_dcx_r:              {zflag_load, zflag_val} = {1'b1, d_i == 8'h01};
               op_inx_r:              {zflag_load, zflag_val} = {1'b1, d_i == 8'hFF};
               op_cpx_ra_r:           {zflag_load, zflag_val} = {1'b1, ix == ra};
               op_cpx_sp_r:           {zflag_load, zflag_val} = {1'b1, ix[D_BITS-1:0] == sp};
               op_ldz_r:              {zflag_load, zflag_val} = {1'b1, inst[1] ?
                                                               (inst[0] ? cflag : ~zflag) :
                                                                inst[0]};
               op_notz_r:             {zflag_load, zflag_val} = {1'b1, acc != 8'h00};
               op_fcmp_r:             {zflag_load, zflag_val} = {1'b1, facc == fx[inst[1:0]]};
            endcase
      end
      else if (decode_state && cond[0] && ret_isr_r)
         {zflag_load, zflag_val} = {1'b1, zflag_isr};
   end

   // =================================================
   // Implement the flags
   // =================================================
   always @(posedge clk)
   begin
      if (!rst_n || reset)
      begin
         cflag_save        <= 1'b0;
         signed_inv_save   <= 1'b0;
      end
      else
      begin
         if (exec_state && cond[0] && d_ok)
         begin
            // Load cflag_save
            if (op_savec_r)
            begin
               cflag_save <= cflag;
               signed_inv_save <= signed_inversion;
            end
         end
         else if (decode_state && cond[0] && ret_isr_r)
         begin
            signed_inv_save <= signed_inv_isr;
            cflag_save <= cflag_save_isr;
         end
      end
   end

   /*
   ==========================================================================
   Instantiate the HW 16-bit divider
   ==========================================================================
   */
   assign cflag_load = (c_load && exec_state && cond[0] && d_ok) ||
                       (decode_state && cond[0] && ret_isr_r);

   generate
   if (WANT_DIV)
   begin : GEN_DIV
      lisa_div 
      #(
            .PC_BITS(PC_BITS)
       )
      i_lisa_div
      (
         .clk                  ( clk                  ),
         .rst_n                ( rst_n                ),
         .reset                ( reset                ),
         .op_start             ( op_div_start_r       ),
         .op_div               ( (op_div_r | div_stage_two) & amode[1]    ),
         .op_rem               ( (op_rem_r | rem_stage_two) & amode[1]    ),
         .op_remu              ( (op_rem_r | rem_stage_two) & ~amode[1]   ),
         .div_rs1              ( div_dividend         ),
         .div_rs2              ( div_divisor          ),
         .div_rd               ( div_result           ),
         .div_ready            ( div_ready            ),
         .cflag                ( cflag                ),
         .cflag_val            ( c_val                ),
         .signed_inversion     ( signed_inversion     ),
         .signed_inv_val       ( signed_inv_val       ),
         .cflag_load           ( cflag_load           ),
         .zflag                ( zflag                ),
         .zflag_val            ( zflag_val            ),
         .zflag_load           ( zflag_load           ),
         .ix                   ( ix                   ),
         .ix_cond              ( ix_cond              ),
         .ix_val               ( ix_val               ),
         .ix_cond_val          ( ix_cond_val          ),
         .ix_load              ( ix_load              ),
         .ra                   ( ra                   ),
         .ra_cond              ( ra_cond              ),
         .ra_val               ( ra_val               ),
         .ra_cond_val          ( ra_cond_val          ),
         .ra_load              ( ra_load              ),
         .ldx_stage_two        ( ldx_stage_two        ),
         .ldx_stage_two_val    ( ldx_stage_two_val    ),
         .ldx_stage_two_load   ( ldx_stage_two_load   )
      );
   end
   else
   begin : GEN_NO_DIV
      assign div_result = 16'h0;
      assign div_ready = 1'b0;

      // =================================================
      // Implement the cflag/zflag and signed_inversion flops
      // =================================================
      reg cflag_r;
      reg zflag_r;
      reg signed_inv_r;
      always @(posedge clk)
         if (!rst_n || reset)
         begin
            cflag_r <= 1'b0;
            zflag_r <= 1'b0;
            signed_inv_r <= 1'b0;
         end
         else
         begin
            if (cflag_load)
            begin
               cflag_r <= c_val;
               signed_inv_r <= signed_inv_val;
            end

            if (zflag_load)
               zflag_r <= zflag_val;
         end

      assign cflag = cflag_r;
      assign zflag = zflag_r;
      assign signed_inversion = signed_inv_r;

      // =================================================
      // Implement IX and RA registers
      // =================================================
      reg [PC_BITS-1:0]          ix_r;
      reg                        ix_cond_r;
      reg [PC_BITS-1:0]          ra_r;
      reg                        ra_cond_r;
      reg                        ldx_stage_two_r;

      always @(posedge clk)
      begin
         if (!rst_n || reset)
         begin
            ix_r      <= {PC_BITS{1'b0}};
            ix_cond_r <= 1'b0;
            ra_r      <= {PC_BITS{1'b0}};
            ra_cond_r <= 1'b0;
            ldx_stage_two_r <= 1'b0;
         end
         else
         begin
            if (ix_load)
            begin
               ix_cond_r <= ix_cond_val;
               ix_r      <= ix_val;
            end
            if (ra_load)
            begin
               ra_r      <= ra_val;
               ra_cond_r <= ra_cond_val;
            end
            if (ldx_stage_two_load)
            begin
               ldx_stage_two_r <= ldx_stage_two_val;
            end
         end
      end
      assign ix      = ix_r;
      assign ix_cond = ix_cond_r;
      assign ra      = ra_r;
      assign ra_cond = ra_cond_r;
      assign ldx_stage_two = ldx_stage_two_r;
   end
   endgenerate

   // ==========================================================================
   // Implement the debugger
   // ==========================================================================
   generate
   if (WANT_DBG && DBG_BRKPOINTS > 0)
   begin : GEN_LISA_DBG
      lisa_dbg
      #(
         .DBG_BRKPOINTS(DBG_BRKPOINTS),
         .PC_BITS(PC_BITS),
         .D_BITS (D_BITS)
       )
      i_lisa_dbg
      (
      `ifdef USE_POWER_PINS
            .VPWR(VPWR),
            .VGND(VGND),
      `endif
         .clk        ( clk         ),
         .rst_n      ( rst_n       ),
                                   
         .inst       ( inst        ),
         .pc         ( pc          ),
         .acc        ( acc         ),
         .sp         ( sp          ),
         .ix         ( ix          ),
         .ra         ( ra          ),
         .cond       ( cond        ),
         .zflag      ( zflag       ),
         .cflag      ( cflag       ),
         .amode      ( amode       ),
         .fetch      ( fetch_state ),
         .brk_inst   ( decode_state & cond[0] & op_brk_r ),
         .stop       ( stop        ),
         .cont_q     ( cont_q      ),
         .f0         ( f0          ),
         .f1         ( f1          ),
         .f2         ( f2          ),
         .f3         ( f3          ),
         .facc       ( facc        ),

         .d_i       ( d_i          ),
         .d_o       ( dbg_d_o      ),
         .d_access  ( dbg_d_access ),
         .d_addr    ( dbg_d_addr   ),
         .d_periph  ( dbg_d_periph ),
//         .d_we      ( dbg_d_we     ),
         .d_rd      ( dbg_d_rd     ),

         .dbg_a      ( dbg_a       ),
         .dbg_di     ( dbg_di      ),
         .dbg_do     ( dbg_do      ),
         .dbg_we     ( dbg_we      ),
         .dbg_rd     ( dbg_rd      ),
         .dbg_ready  ( dbg_ready_c ),
         .dbg_halted ( dbg_halted  )
      );
   end
   else if (WANT_DBG)
   begin : GEN_SIMPLE_DEBUG
      // =======================================================
      // Implement simple debugger in this module directly
      // =======================================================

      // =======================================================
      // Data SRAM read/write state machine
      // =======================================================

      // =======================================================
      // Debug bus read data
      // =======================================================
      reg  [15:0] dbg_do_r;
      reg         halt_r;
      reg         cont_q_r;
      wire        cont;
      wire [3:0]  pc_bits;
      wire [3:0]  d_bits;

      always @(posedge clk)
      begin
         if (~rst_n)
         begin
            halt_r <= 1'b1;
            cont_q_r <= 1'b0;
         end
         else
         begin
            if (dbg_we && dbg_a == 8'h0)
            begin
               // Save halt bit
               halt_r <= dbg_di[0];

               // Test for resume or single_step
               if ((dbg_di[1] || dbg_di[2]) && cont)
                  cont_q_r <= 1'b1;
            end
            else
            begin
               // Test for end of write cycle to drive cont_q_r low
               if (dbg_we == 1'b0)
                  cont_q_r <= 1'b0;

               // Test for halt from breakpoint
               if (op_brk && fetch_state)
                  halt_r <= 1'b1;
            end
         end
      end

      always @*
      begin
         dbg_do_r = 16'h0;
         case (dbg_a)
         0:    dbg_do_r = { d_bits, pc_bits, 4'h1, 3'h0, halt_r };
         1:    dbg_do_r = { 1'h0, amode,  cond, cflag, zflag, acc };
         2:    dbg_do_r = { {(16-PC_BITS){1'b0}}, pc };
         3:    dbg_do_r = { {(16-D_BITS){1'b0}},  sp };
         4:    dbg_do_r = { {(16-PC_BITS){1'b0}}, ra };
         5:    dbg_do_r = { {(16-PC_BITS){1'b0}}, ix };
         6:    dbg_do_r = { acc_delayed_val, d_i };
         7:    dbg_do_r = { {(16-D_BITS){1'b0}}, d_addr};
         15:   dbg_do_r = inst;
         endcase
      end

      assign dbg_do     = dbg_do_r;
      assign dbg_halted = halt_r;
      assign stop       = (halt_r | op_brk) && !cont;
      assign cont       = dbg_we && dbg_a == 8'h0 && |dbg_di[2:1] && ~cont_q_r;
      assign cont_q     = cont_q_r;
      assign pc_bits    = PC_BITS;
      assign d_bits     = D_BITS;

      // ==================================================
      // With this debug mode, we perform data bus access
      // by replacing opcodes and then single-stepping.
      // ==================================================
      assign dbg_d_addr   = {D_BITS{1'b0}};
      assign dbg_d_rd     = 1'b0;
      assign dbg_d_o      = 8'h00;
      assign dbg_d_periph = 1'b0;
      assign dbg_d_access = 1'b0;
   end
   else
   begin : GEN_NO_DEBUG
      // No debugger
      assign dbg_do       = {PC_BITS{1'b0}};
      assign stop         = 1'b0;
      assign cont_q       = 1'b0;
      assign dbg_ready    = 1'b1;

      assign dbg_d_addr   = {D_BITS{1'b0}};
      assign dbg_d_rd     = 1'b0;
      assign dbg_d_o      = 8'h00;
      assign dbg_d_periph = 1'b0;
      assign dbg_d_access = 1'b0;
      assign dbg_halted   = 1'b0;
   end
   endgenerate

   /*
   ==================================================
   Floating point (Brain float) operations

    op_tfa                 Transfer facc (half) to acc
    op_taf                 Transfer a to facc (half)
    op_fmul                Float mult facc * fx.  Result in facc
    op_fdiv                Float mult facc / fx.  Result in facc
    op_fadd                Float add  facc + fx.  Result in facc
    op_fswqp               Swap facc and fx.
   ==================================================
   */
`ifdef WANT_BF16
   assign op_fops = op_tfa_r | op_taf_r | op_fmul_r | op_fadd_r | op_fclr_r |
                    op_fneg_r | op_fswap_r | op_itof_r | op_fcmp_r | op_ftoi_r;
   wire [15:0] itof_val;
   wire [15:0] ftoi_val;
   (* keep = "true" *)
   reg   [15:0] facc_val;
   reg          fdiv_r;
	wire	[0:0]                      s_op1_w;
	wire	[(8+1)-1:0]                extE_op1_w;
	wire                             isInf_op1_w;
	wire                             isZ_op1_w;
	wire                             isSNAN_op1_w;
	wire                             isQNAN_op1_w;
	wire                             isDN_op1_w;
	wire	[0:0]                      s_op2_w;
	wire	[(8+1)-1:0]                extE_op2_w;
	wire                             isInf_op2_w;
	wire                             isZ_op2_w;
	wire                             isSNAN_op2_w;
	wire                             isQNAN_op2_w;
	wire                             isDN_op2_w;

   always @*
   begin
      facc_val = 16'h0;
      case (1'b1)
      op_taf_r:   facc_val = { acc, acc };
      op_fmul_r:  facc_val = fmul_result;
      op_fdiv_r:  facc_val = fdiv_result;
      op_fadd_r:  facc_val = fadd_result;
      op_fswap_r: facc_val = fx[inst[1:0]];
      op_itof_r:  facc_val = itof_val;
      op_ftoi_r:  facc_val = ftoi_val;
      op_fclr_r:  facc_val = 16'h0;
      endcase
   end

   always @(posedge clk)
   begin
      if (~rst_n)
      begin
         // Zero the floating point registers
         facc <= 16'h0;
         f0 <= 16'h0;
         f1 <= 16'h0;
         f2 <= 16'h0;
         f3 <= 16'h0;
         fdiv_r <= 1'b0;
      end
      else
      begin
         fdiv_r <= op_fdiv_r;

         // Load operations for floating point registers
         if (exec_state && cond[0])
         case (1'b1)
         op_taf_r:
            begin
               case (inst[0])
               1'h0:    facc[7:0]  <= facc_val[7:0];
               1'h1:    facc[15:8] <= facc_val[15:8];
               endcase
            end
         op_fmul_r: facc <= facc_val;
         op_fadd_r: facc <= facc_val;
         op_fneg_r: case (inst[1:0])
                  2'h0:  f0[15] <= ~f0[15];
                  2'h1:  f1[15] <= ~f1[15];
                  2'h2:  f2[15] <= ~f2[15];
                  2'h3:  f3[15] <= ~f3[15];
                  endcase
         op_fswap_r:
            begin
               facc <= facc_val;
               case (inst[1:0])
               2'h0: f0 <= facc;
               2'h1: f1 <= facc;
               2'h2: f2 <= facc;
               2'h3: f3 <= facc;
               endcase
            end
         op_itof_r: facc <= facc_val;
         op_ftoi_r: facc <= facc_val;
         op_fclr_r: facc <= facc_val;
         endcase
         else if (stg2_state & op_fdiv_r & fdiv_ready)
            facc <= facc_val;
      end
   end

   assign f_half[0] = facc[7:0];
   assign f_half[1] = facc[15:8];
   assign fx[0] = f0;
   assign fx[1] = f1;
   assign fx[2] = f2;
   assign fx[3] = f3;
   wire [15:0] fadd_op2;
   wire [15:0] fmul_op2;
   wire [15:0] fdiv_op2;

   assign fadd_op2 = fx[inst[1:0]] & {16{op_fadd_r}};
   fadd i_fadd
   (
      .a_in          ( facc          ),
      .b_in          ( fadd_op2      ),
      .round_to_zero ( amode[2]      ),
      .s_op1_i         ( s_op1_w             ),
      .extE_op1_i      ( extE_op1_w          ),
      .isInf_op1_i     ( isInf_op1_w         ),
      .isZ_op1_i       ( isZ_op1_w           ),
      .isSNAN_op1_i    ( isSNAN_op1_w        ),
      .isQNAN_op1_i    ( isQNAN_op1_w        ),
      .isDN_op1_i      ( isDN_op1_w          ),
      .s_op2_i         ( s_op2_w             ),
      .extE_op2_i      ( extE_op2_w          ),
      .isInf_op2_i     ( isInf_op2_w         ),
      .isZ_op2_i       ( isZ_op2_w           ),
      .isSNAN_op2_i    ( isSNAN_op2_w        ),
      .isQNAN_op2_i    ( isQNAN_op2_w        ),
      .isDN_op2_i      ( isDN_op2_w          ),
      .result        ( fadd_result   )
   );

   assign fmul_op2 = fx[inst[1:0]] & {16{op_fmul_r}};
   fmul i_fmul
   (
      .a_in    ( facc          ),
      .b_in    ( fmul_op2      ),
      .s_op1_i         ( s_op1_w             ),
      .extE_op1_i      ( extE_op1_w          ),
      .isInf_op1_i     ( isInf_op1_w         ),
      .isZ_op1_i       ( isZ_op1_w           ),
      .isSNAN_op1_i    ( isSNAN_op1_w        ),
      .isQNAN_op1_i    ( isQNAN_op1_w        ),
      .isDN_op1_i      ( isDN_op1_w          ),
      .s_op2_i         ( s_op2_w             ),
      .extE_op2_i      ( extE_op2_w          ),
      .isInf_op2_i     ( isInf_op2_w         ),
      .isZ_op2_i       ( isZ_op2_w           ),
      .isSNAN_op2_i    ( isSNAN_op2_w        ),
      .isQNAN_op2_i    ( isQNAN_op2_w        ),
      .isDN_op2_i      ( isDN_op2_w          ),
      .result  ( fmul_result   )
   );

   itobf16 i_itobf16
   (
      .in       ( facc         ),
      .is_signed( amode[1]     ),
      .bf16_out ( itof_val     )
   );

   bf16toi i_bf16toi
   (
      .bf16_in  ( facc         ),
      .i_signed ( amode[1]     ),
      .i_o      ( ftoi_val     )
   );

   assign fdiv_op2 = fx[inst[1:0]];
   lampFPU_div_top i_bf16div
   (
      .clk             ( clk                 ),
      .rst             ( !rst_n              ),
      .do_div          ( op_fdiv_r & !fdiv_r ),
      .padv_i          ( fdiv_complete       ),
      .rndMode_i       ( amode[2]            ),
      .op1_i           ( facc                ),
      .op2_i           ( fdiv_op2            ),
      .result_o        ( fdiv_result         ),
      .isResultValid_o ( fdiv_valid          ),
      .isReady_o       ( fdiv_ready          ),
      .s_op1_r         ( s_op1_w             ),
      .extE_op1_r      ( extE_op1_w          ),
      .isInf_op1_r     ( isInf_op1_w         ),
      .isZ_op1_r       ( isZ_op1_w           ),
      .isSNAN_op1_r    ( isSNAN_op1_w        ),
      .isQNAN_op1_r    ( isQNAN_op1_w        ),
      .isDN_op1_r      ( isDN_op1_w          ),
      .s_op2_r         ( s_op2_w             ),
      .extE_op2_r      ( extE_op2_w          ),
      .isInf_op2_r     ( isInf_op2_w         ),
      .isZ_op2_r       ( isZ_op2_w           ),
      .isSNAN_op2_r    ( isSNAN_op2_w        ),
      .isQNAN_op2_r    ( isQNAN_op2_w        ),
      .isDN_op2_r      ( isDN_op2_w          )
   );
   assign fdiv_complete = !op_fdiv_r | fdiv_ready;
`endif

`ifdef SIMULATION
   reg [63:0] ascii_instr;

   /*
   ==================================================
   Assign ascii_instr anytime opcode or subop changes.
   ==================================================
   */
   always @*
   begin
    if (decode_state)
    begin
      if (op_adx)                                  ascii_instr = "adx";
      if (op_ads)                                  ascii_instr = "ads";
      if (op_tax)                                  ascii_instr = "tax";
      if (op_taxu)                                 ascii_instr = "taxu";
      if (op_addax)                                ascii_instr = "addax";
      if (op_addaxu)                               ascii_instr = "addaxu";
      if (op_subax)                                ascii_instr = "subax";
      if (op_subaxu)                               ascii_instr = "subaxu";
      if (op_call_ix)                              ascii_instr = "call ix";
      if (op_jmp_ix)                               ascii_instr = "jmp ix";
      if (op_xchg_sp)                              ascii_instr = "xchg sp";
      if (op_xchg_ra)                              ascii_instr = "xchg ra";
      if (op_xchg_ia)                              ascii_instr = "xchg ia";
      if (op_spix)                                 ascii_instr = "spix";
      if (op_mul)                                  ascii_instr = "mul";
      if (op_mulu)                                 ascii_instr = "mulu";
      if (op_cpi)                                  ascii_instr = "cpi";
      if (op_cmp)                                  ascii_instr = "cmp";  
      if (op_cpx_ra)                               ascii_instr = "cpx rx";  
      if (op_cpx_sp)                               ascii_instr = "cpx sp";  
      if (op_if)                                   ascii_instr = "if";
      if (op_btst)                                 ascii_instr = "btst";
      if (op_dcx)                                  ascii_instr = "dcx";
      if (op_inx)                                  ascii_instr = "inx";
      if (op_stxx)                                 ascii_instr = "stxx";
      if (op_ldxx)                                 ascii_instr = "ldxx";
      if (op_shr16)                                ascii_instr = "shr16";
      if (op_shl16)                                ascii_instr = "shl16";
      if (op_savec)                                ascii_instr = "savec";
      if (op_restc)                                ascii_instr = "restc";
      if (op_ldz)                                  ascii_instr = "ldz";
      if (op_brk)                                  ascii_instr = "brk";
      if (op_push_ix)                              ascii_instr = "push_ix";
      if (op_pop_ix)                               ascii_instr = "pop_ix";
      if (op_fdiv)                                 ascii_instr = "fdiv";
      if (op_fmul)                                 ascii_instr = "fmul";
      if (op_fadd)                                 ascii_instr = "fadd";
      if (op_fneg)                                 ascii_instr = "fneg";
      if (op_taf)                                  ascii_instr = "taf";
      if (op_tfa)                                  ascii_instr = "tfa";
      if (op_fswap)                                ascii_instr = "fswap";
      if (op_itof)                                 ascii_instr = "itof";
      if (op_ftoi)                                 ascii_instr = "ftoi";
      if (op_fclr)                                 ascii_instr = "fclr";
      if (op_fcmp)                                 ascii_instr = "fcmp";
      if (op_ldirq)                                ascii_instr = "ldirq";
      if (op_stirq)                                ascii_instr = "stirq";
      if (op_eidi)                                 ascii_instr = "eidi";
      if (inst[`PWORD_SIZE-1 -: 11] == 11'h50E)    ascii_instr = "ldac";
      if (inst[`PWORD_SIZE-1] == 0)                ascii_instr = "jal";
      if (inst[`PWORD_SIZE-1 -: 6] == 6'h20)       ascii_instr = "ldi";
      if (inst[`PWORD_SIZE-1 -: 6] == 6'h23)       ascii_instr = "ret #";
`ifdef SIMULATION
      if (op_ret)                                  ascii_instr = "ret";
      if (op_rc)                                   ascii_instr = "rc";
      if (op_rz)                                   ascii_instr = "rz";
      if (op_rets)                                 ascii_instr = "rets";
`endif
      if (op_amode)                                ascii_instr = "amode";
      if (inst[`PWORD_SIZE-1 -: 6] == 6'h24)       ascii_instr = "adc";
      if (inst[`PWORD_SIZE-1 -: 14] == 14'h2800)   ascii_instr = "shl";
      if (inst[`PWORD_SIZE-1 -: 14] == 14'h2801)   ascii_instr = "shr";
      if (inst[`PWORD_SIZE-1 -: 13] == 13'h1401)   ascii_instr = "ldc";
      if (inst[`PWORD_SIZE-1 -: 14] == 14'h2804)   ascii_instr = "txa";
      if (inst[`PWORD_SIZE-1 -: 14] == 14'h2820)   ascii_instr = "push a";
      if (inst[`PWORD_SIZE-1 -: 14] == 14'h2830)   ascii_instr = "pop a";
      if (inst[`PWORD_SIZE-1 -: 14] == 14'h281C)   ascii_instr = "nop";
      if (inst[`PWORD_SIZE-1 -: 14] == 14'h2858)   ascii_instr = "sra";
      if (inst[`PWORD_SIZE-1 -: 14] == 14'h2859)   ascii_instr = "lra";
      if (inst[`PWORD_SIZE-1 -: 5] == 5'b10101)    ascii_instr = "bnz";
      if (inst[`PWORD_SIZE-1 -: 5] == 5'b10110)    ascii_instr = "br";
      if (inst[`PWORD_SIZE-1 -: 5] == 5'b10111)    ascii_instr = "bz";
      if (inst[`PWORD_SIZE-1 -: 6] == 6'h30)       ascii_instr = "add";
      if (inst[`PWORD_SIZE-1 -: 6] == 6'h32)       ascii_instr = "sub";
      if (inst[`PWORD_SIZE-1 -: 6] == 6'h34)       ascii_instr = "and";
      if (inst[`PWORD_SIZE-1 -: 6] == 6'h35)       ascii_instr = "andi";
      if (inst[`PWORD_SIZE-1 -: 6] == 6'h36)       ascii_instr = "or";
      if (inst[`PWORD_SIZE-1 -: 6] == 6'h38)       ascii_instr = "xor";
      if (inst[`PWORD_SIZE-1 -: 7] == 7'h78)       ascii_instr = "ldax(ix)";
      if (inst[`PWORD_SIZE-1 -: 7] == 7'h79)       ascii_instr = "ldax(sp)";
      if (inst[`PWORD_SIZE-1 -: 7] == 7'h7C)       ascii_instr = "stax(ix)";
      if (inst[`PWORD_SIZE-1 -: 7] == 7'h7D)       ascii_instr = "stax(sp)";
      if (inst[`PWORD_SIZE-1 -: 6] == 6'h3D)       ascii_instr = "lda";
      if (inst[`PWORD_SIZE-1 -: 6] == 6'h3F)       ascii_instr = "sta";
      if (inst[`PWORD_SIZE-1 -: 6] == 6'h3B)       ascii_instr = "swap";
      if (inst[`PWORD_SIZE-1 -: 6] == 6'h37)       ascii_instr = "swapi";
      if (op_ldx | ldx_stage_two)                  ascii_instr = "ldx";
      if (op_lddiv | lddiv_stage_two)              ascii_instr = "lddiv";
      if ((op_div | div_stage_two) & amode[1])     ascii_instr = "div";
      if ((op_div | div_stage_two) & ~amode[1])    ascii_instr = "divu";
      if ((op_rem | rem_stage_two) & amode[1])     ascii_instr = "rem";
      if ((op_rem | rem_stage_two) & ~amode[1])    ascii_instr = "remu";

      if (op_if)
      begin
         if (inst[3])                      ascii_instr = "iftt";
         if (inst[4])                      ascii_instr = "ifte";
      end
    end
   end
`endif

/*
   ila_0 i_ila_0
   (
      .clk           ( clk       ),
      .probe0        ( i_addr[12:0]    ),
      .probe1        ( inst      ),
      .probe2        ( state     ),
      .probe3        ( acc       ),
      .probe4        ( d_addr    ),
      .probe5        ( d_i       ),
      .probe6        ( d_o       ),
      .probe7        ( d_we      ),
      .probe8        ( d_rd      ),
      .probe9        ( d_periph  ),
      .probe10       ( cflag     ),
      .probe11       ( cond      ),
      .probe12       ( zflag     ),
      .probe13       ( c_val     ),
      .probe14       ( c_load    ),
      .probe15       ( c_cpi     ),
      .probe16       ( ra_cond   ),
      .probe17       ( ra_cond_val ),
      .probe18       ( ra_load   ),
      .probe19       ( sp        ),
      .probe20       ( ra        ),
      .probe21       ( ix        ),
      .probe22       ( inst_ready )
   );
*/

endmodule

