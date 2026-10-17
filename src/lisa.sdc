# The constraints of tt_um_lisa: LibreLane's defaults (the clock from
# CLOCK_PERIOD, the I/O delays, max fanout/transition/capacitance) plus the
# core's multi-cycle paths, the ones the TT07 build (OpenLane 2, impl.sdc,
# 30 ns) closed with.  An instruction takes the fetch, pre-decode and decode
# states: what the PC, the instruction window, the breakpoint and debug
# registers reach - the next PC, IX, RA, IA, SP, cond, ie, the BF16
# accumulator, the divider's operands and flags - is registered two or three
# clocks after the source changed.
#
# The flops are found through their Q nets, which keep the RTL names
# (i_lisa_core.pc[*] ...) while the cells are numbered; a group may be
# reached by several names because Yosys names a flattened net after any of
# its aliases (the debugger's data register came out as core_inst_o, the
# divider's operands carry lisa_div's port names).
source $::env(SCRIPTS_DIR)/base.sdc

# The flops (or latches: the breakpoint registers) driving the nets, through
# buffers or inverters synthesis or the resizer put between (never through
# other logic).  Several patterns may be given; the result is the union.
proc lisa_regs {args} {
    set regs {}
    foreach pattern $args {
        foreach net [get_nets -quiet $pattern] {
            set pins [get_pins -quiet -of_objects $net -filter {direction == output}]
            for {set hop 0} {$hop < 6 && [llength $pins] > 0} {incr hop} {
                set cell [get_cells -quiet -of_objects [lindex $pins 0]]
                if {[llength $cell] == 0} { break }
                set lib [get_name [get_lib_cells -of_objects $cell]]
                if {[string match "*df*" $lib] || [string match "*dl*" $lib]} {
                    if {[lsearch -exact $regs $cell] < 0} { lappend regs $cell }
                    break
                }
                set in [get_pins -quiet -of_objects $cell -filter {direction == input}]
                if {[llength $in] != 1} { break }
                set pins [get_pins -quiet -of_objects [get_nets -of_objects $in] -filter {direction == output}]
            }
        }
    }
    return $regs
}

# (the hold count is computed first: OpenSTA's read_sdc takes the calling
# command's text as a list when it records the SDC line of an exception, and
# an inline [expr {...}] is not one)
proc lisa_mcp {cycles from to} {
    if {[llength $from] > 0 && [llength $to] > 0} {
        set hold [expr {$cycles - 1}]
        set_multicycle_path $cycles -setup -from $from -to $to
        set_multicycle_path $hold -hold -from $from -to $to
    }
}

set dbg {i_lisa_core.GEN_LISA_DBG.i_lisa_dbg}
set div {i_lisa_core.GEN_DIV.i_lisa_div}

# sources
set pc         [lisa_regs {i_lisa_core.pc[*]}]
# the streaming fetch's window (inst_stream.v): its count and first address
# decide the hit, as the TT07 cache line's valid bit and address did
set win_count  [lisa_regs {i_inst_stream.count[*]}]
set win_head   [lisa_regs {i_inst_stream.head_addr[*]}]
# and its words: the one at the PC's offset is the instruction, stable from
# the fetch state to the execute state (three cycles: fetch, decode, exec;
# a slide moves the same word with the offset) - added 2026-10-17, after
# rc2, when the FPGA build showed the path (window -> fadd operand select
# -> BF16 adder -> facc, the longest single-cycle one left)
set win_data   [lisa_regs {i_inst_stream.window[*]}]
set brk        [lisa_regs "$dbg.brk_r*"]
set dbg_a      [lisa_regs {dbg_a[*]} {i_lisa_core.dbg_a[*]} {i_debug_ctrl.s_debug_arg[*]}]
set dbg_di     [lisa_regs {dbg_di[*]} {core_inst_o[*]} {i_lisa_core.dbg_di[*]} {i_lisa_core.inst_o[*]}]
set dbg_we     [lisa_regs {dbg_we} {i_lisa_core.dbg_we} {i_debug_ctrl.s_debug_wr}]
set dbg_halted [lisa_regs {dbg_halted} {i_lisa_core.dbg_halted} "$dbg.halted"]
set cont_q     [lisa_regs "$dbg.cont_q_r" "$dbg.cont_q"]
set predec     [lisa_regs {i_lisa_core.predec_state}]
set d_we_r     [lisa_regs {i_lisa_core.d_we_r}]

# destinations
set facc       [lisa_regs {i_lisa_core.facc[*]}]
set ix         [lisa_regs {i_lisa_core.ix[*]}]
set ra         [lisa_regs {i_lisa_core.ra[*]}]
set ia         [lisa_regs {i_lisa_core.ia[*]}]
set sp         [lisa_regs {i_lisa_core.sp[*]}]
set cond       [lisa_regs {i_lisa_core.cond[*]}]
set ie         [lisa_regs {i_lisa_core.ie}]
set isr_jump   [lisa_regs {i_lisa_core.isr_jump}]
# rev 2: the ISR shadows (issue 6), written in the same clock and branch as
# ia, isr_jump and ie when the interrupt is taken
set isr_sh     [lisa_regs {i_lisa_core.cflag_isr} {i_lisa_core.zflag_isr} {i_lisa_core.signed_inv_isr} \
                          {i_lisa_core.cflag_save_isr} {i_lisa_core.signed_inv_live_isr} {i_lisa_core.amode_isr[*]}]
set div_rs1    [lisa_regs "$div.div_rs1\[*\]" {i_lisa_core.div_rs1[*]}]
set div_rs2    [lisa_regs "$div.div_rs2\[*\]" {i_lisa_core.div_rs2[*]}]
set div_zflag  [lisa_regs "$div.zflag" "$div.zflag_r"]
set div_cond   [lisa_regs "$div.cond"]
set div_ixc    [lisa_regs "$div.ix_cond"]
set div_sinv   [lisa_regs "$div.signed_inversion"]

set groups {pc win_count win_head win_data brk dbg_a dbg_di dbg_we dbg_halted cont_q predec d_we_r
            facc ix ra ia sp cond ie isr_jump isr_sh div_rs1 div_rs2 div_zflag div_cond div_ixc div_sinv}
set report "lisa.sdc:"
foreach g $groups { append report " $g [llength [set $g]]" }
puts $report
foreach g $groups {
    if {[llength [set $g]] == 0} { puts "\[WARNING\] lisa.sdc: no registers found for $g" }
}

# the registers written at the end of an instruction (three clocks from the
# PC) and the divider's operands (two)
set core3 [concat $facc $ix $ra $ia $sp $cond $ie $isr_jump $isr_sh $div_zflag $div_cond $div_ixc $div_sinv]
set core2 [concat $div_rs1 $div_rs2]

lisa_mcp 3 $pc [concat $pc $core3]
lisa_mcp 2 $pc $core2
foreach src [list $win_count $win_head $win_data] {
    lisa_mcp 3 $src $core3
    lisa_mcp 2 $src $core2
}

# the debugger: its address register is seen like the PC; its data, write,
# halted and continue strobes and the breakpoint compare reach the registers
# two clocks later
lisa_mcp 3 $dbg_a [concat $pc $facc $ix $ra $ia $sp $cond $ie $isr_sh $div_cond $div_ixc $div_sinv]
lisa_mcp 2 $dbg_a $core2
set dbg_to [concat $facc $div_rs1 $div_rs2 $ra $ia $ix $sp $cond $div_cond $div_ixc]
foreach src [list $brk $dbg_we $dbg_halted $dbg_di $cont_q] {
    lisa_mcp 2 $src $dbg_to
}

# the BF16 accumulator is loaded only in the decode state
lisa_mcp 2 $predec $facc
lisa_mcp 2 $d_we_r $facc
