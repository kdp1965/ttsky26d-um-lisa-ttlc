# The core's multi-cycle paths: src/lisa.sdc's exceptions, the ones the
# chip closes with, on the Vivado netlist.  Sourced by build.tcl after
# synth_design (the flops must exist).  An instruction takes the fetch,
# pre-decode and decode states: what the PC, the instruction window, the
# breakpoint and debug registers reach - the next PC, IX, RA, IA, SP, cond,
# ie, the BF16 accumulator, the divider's flags - is registered two or three
# clocks after the source changed.
#
# Vivado keeps the RTL names (<reg>_reg[n], a generate scope as a prefix),
# so the groups are found by name.  With the divider present (WANT_DIV),
# IX and its condition bit are lisa_div's b and ix_hi registers, RA
# and the signed-inversion flag its result register, and the live flags its
# cflag_r / zflag_r / cond; the debugger's address is s_debug_arg[23:16]
# and its data s_debug_arg[15:0].
#
# The window's data words are a 3-cycle source here and in lisa.sdc since
# 2026-10-17 (they were not in rc2's sign-off).
# lisa.sdc's fetch-state group (its one-hot fetch flop to the accumulator,
# three cycles) is ported through the net it passes: the state register is
# binary here and also decodes the execute state that loads the
# accumulator, so it cannot be the source by name.  The fetch state (and a
# breakpoint's stop) make the instruction stream's core_i_ready, the select
# of the core's instruction mux (the window word or the latched one), and
# everything behind that mux - the decode, the operand select, the BF16
# adder - ends at the accumulator: 29 levels, 1.3 ns over at 50 MHz
# (2026-10-17), and never a real transfer, since the accumulator loads in
# the execute state, where the select is held at the latched instruction.
# Not ported: lisa.sdc's predec group (the chip's one-hot pre-decode flop)
# and its div_rs1 / div_rs2 group (nets of combinational operands, which
# its register walk resolved to the IX low byte and the accumulator; the IX
# byte is in the 3-cycle group below).

set C lisa/i_lisa_core
set D $C/GEN_DIV.i_lisa_div
set G $C/GEN_LISA_DBG.i_lisa_dbg
set I lisa/i_

# the sequential cells whose names match any of the glob patterns
proc lisa_regs {args} {
   set cells {}
   foreach pattern $args {
      foreach c [get_cells -hierarchical -quiet -filter "IS_SEQUENTIAL && NAME =~ $pattern"] {
         if {[lsearch -exact $cells $c] < 0} { lappend cells $c }
      }
   }
   return $cells
}
# the bits lo..hi of a register vector
proc lisa_bits {pattern lo hi} {
   set cells {}
   foreach c [lisa_regs $pattern] {
      if {[regexp {\[(\d+)\]$} [get_property NAME $c] -> b] && $b >= $lo && $b <= $hi} {
         lappend cells $c
      }
   }
   return $cells
}
proc lisa_mcp {cycles from to} {
   if {[llength $from] > 0 && [llength $to] > 0} {
      set_multicycle_path $cycles -setup -from $from -to $to
      set_multicycle_path [expr {$cycles - 1}] -hold -from $from -to $to
   }
}

# sources
set pc         [lisa_regs $C/pc_reg*]
set win_count  [lisa_regs ${I}inst_stream/count_reg*]
set win_head   [lisa_regs ${I}inst_stream/head_addr_reg*]
# the window's words: the one at the PC's offset is the instruction, stable
# from the fetch state to the execute state (Ken, 2026-10-17: three cycles,
# which is why there are fetch, decode and exec states); a slide moves the
# same word with the offset
set win_data   [lisa_regs ${I}inst_stream/window_reg*]
set brk        [lisa_regs $G/LISA_BRK_BITS*brk_r*_latch/Q_reg*]
set dbg_a      [lisa_bits ${I}debug_ctrl/s_debug_arg_reg* 16 23]
set dbg_di     [lisa_bits ${I}debug_ctrl/s_debug_arg_reg* 0 15]
set dbg_we     [lisa_regs ${I}debug_ctrl/s_debug_wr_reg*]
set dbg_halted [lisa_regs $G/halted_reg*]
# cont_q is cont_q_r | step_r | skip_r (lisa_dbg.v): the step and skip levels
# hold until the instruction retires, like the continue strobe; lisa.sdc's
# walk of the cont_q net found only cont_q_r
set cont_q     [lisa_regs $G/cont_q_r_reg* $G/step_r_reg* $G/skip_r_reg*]
set d_we_r     [lisa_regs $C/d_we_r_reg*]
# the latched instruction: written in the fetch state only (inst_ready is
# hit & fetch_state), read by the operand selects through the pre-decode,
# decode and execute states
set inst_r     [lisa_regs $C/inst_r_reg*]
# the decoded operation flags: re-registered every clock from the decode
# of inst, so settled at the end of the fetch state like inst_r
set ops        [lisa_regs $C/op_*_r_reg*]
# the BF16 registers: written at the end of an execute state only
set fx         [lisa_regs $C/f0_reg* $C/f1_reg* $C/f2_reg* $C/f3_reg*]
# destinations
set facc       [lisa_regs $C/facc_reg*]
# the third chip (REV3.md): IX = {ix_hi[6:0], b[15:0]} with its condition bit
# in ix_hi[7]; RA = {ra_hi[7:0], result[14:0]}, result[15] signed_inversion
set ix         [concat [lisa_bits $D/b_reg* 0 15] [lisa_bits $D/ix_hi_reg* 0 6]]
set ra         [concat [lisa_bits $D/result_reg* 0 14] [lisa_regs $D/ra_hi_reg*]]
set ia         [lisa_regs $C/ia_reg*]
set sp         [lisa_regs $C/sp_reg*]
set cond       [lisa_regs $C/cond_reg*]
set ie         [lisa_regs $C/ie_reg*]
set isr_jump   [lisa_regs $C/isr_jump_reg*]
set isr_sh     [lisa_regs $C/cflag_isr_reg* $C/zflag_isr_reg* $C/signed_inv_isr_reg* \
                          $C/cflag_save_isr_reg* $C/signed_inv_live_isr_reg* $C/amode_isr_reg*]
set div_zflag  [lisa_regs $D/zflag_r_reg*]
set div_cond   [lisa_regs $D/cond_reg*]
set div_ixc    [lisa_bits $D/ix_hi_reg* 7 7]
set div_sinv   [lisa_bits $D/result_reg* 15 15]

set groups {pc win_count win_head win_data brk dbg_a dbg_di dbg_we dbg_halted cont_q d_we_r inst_r ops fx
            facc ix ra ia sp cond ie isr_jump isr_sh div_zflag div_cond div_ixc div_sinv}
set report "lisa_arty_mcp:"
foreach g $groups { append report " $g [llength [set $g]]" }
puts $report
foreach g $groups {
   if {[llength [set $g]] == 0} { error "lisa_arty_mcp: no registers found for $g" }
}

# the registers written at the end of an instruction, three clocks from the
# PC and the instruction window
set core3 [concat $facc $ix $ra $ia $sp $cond $ie $isr_jump $isr_sh $div_zflag $div_cond $div_ixc $div_sinv]
lisa_mcp 3 $pc [concat $pc $core3]
foreach src [list $win_count $win_head $win_data] {
   lisa_mcp 3 $src $core3
}
# the debugger: its address register is seen like the PC; its data, write,
# halted and continue strobes and the breakpoint compare reach the
# registers two clocks later
lisa_mcp 3 $dbg_a [concat $pc $facc $ix $ra $ia $sp $cond $ie $isr_sh $div_cond $div_ixc $div_sinv]
set dbg_to [concat $facc $ra $ia $ix $sp $cond $div_cond $div_ixc]
foreach src [list $brk $dbg_we $dbg_halted $dbg_di $cont_q] {
   lisa_mcp 2 $src $dbg_to
}
# the BF16 accumulator is loaded only in the decode state
lisa_mcp 2 $d_we_r $facc
# the fetch state's select of the instruction mux (see the top): three
# cycles to the accumulator through the stream's core_i_ready net, whatever
# the source (the state register, a breakpoint's stop, the window's hit)
set i_ready [get_nets -hierarchical -quiet -filter "NAME =~ *core_i_ready"]
if {[llength $i_ready] == 0} {
   # synthesis may keep another of the net's aliases: take the net on the
   # stream's core_i_ready output pin, whatever it is called
   set i_ready [get_nets -quiet -of_objects [get_pins -hierarchical -quiet -filter "REF_PIN_NAME == core_i_ready && DIRECTION == OUT"]]
}
puts "lisa_arty_mcp: core_i_ready nets [llength $i_ready]"
if {[llength $i_ready] == 0} { error "lisa_arty_mcp: the core_i_ready net was not found" }
puts "lisa_arty_mcp: core_i_ready = [get_property NAME $i_ready]"
set_multicycle_path 3 -setup -through $i_ready -to $facc
set_multicycle_path 2 -hold  -through $i_ready -to $facc
# the BF16 adder's cone into the accumulator (29 levels, 20.5 ns here):
# the accumulator loads only at the end of the execute state or the stage
# after, and everything the adder takes was written three or more clocks
# before - the latched instruction and the operation flags at the end of
# the fetch state (the operand select fx[inst[1:0]] and the operand gate),
# the BF16 registers and the accumulator itself at the end of the previous
# instruction's execute state, which is at least three states back.  Each
# of these was the worst path in turn once the select above was relaxed
# (0.5, 0.24 ns over).
lisa_mcp 3 [concat $inst_r $ops $fx $facc] $facc
