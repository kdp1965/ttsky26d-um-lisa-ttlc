# LISA on the Arty A7-35T: the Vivado non-project flow, synthesis to
# bitstream.  Run by the Makefile:
#   vivado -mode batch -source build.tcl -tclargs <part> <clock divider>
# Results in build/: lisa_arty.bit, timing.rpt, util.rpt, drc.rpt and the
# checkpoints.  The last lines of the log give the worst setup / hold slack.
set part [expr {$argc > 0 ? [lindex $argv 0] : "xc7a35ticsg324-1L"}]
set div  [expr {$argc > 1 ? [lindex $argv 1] : 20}]   ;# CLK_DIVIDE: 20 = 50 MHz, 25 = 40 MHz
set here [file dirname [file normalize [info script]]]
set src  [file normalize $here/../../src]
set gen  $here/gen
set out  $here/build
file mkdir $out

# The chip's sources as test/Makefile lists them (info.yaml's list), with
# debug_regs.v and lisa_dbg.v from gen/ (latch2flop.py: the sky130
# latches as flops) and the FPGA models of the two sky130 cells.
set sources {
   tt_um_pettit_lisa.v RAM32.v
   lisa_core.v lisa_dbg.v lisa_div.v lisa_periph.v lisa_io_mux.v
   lisa_qqspi.v lisa_qspi_controller.v lisa_rx8n.v lisa_tx8n.v lisa_i2c.v lisa_spi.v lisa_ttlcio.v lisa_timer3.v lisa_ws2812.v lisa_cyccnt.v lisa_wdt.v lisa_pdm.v
   debug_ctrl.v debug_autobaud.v debug_brg.v debug_regs.v
   data_cache8.v inst_stream.v
   i2c_master_byte_ctrl.v i2c_master_bit_ctrl.v lisa_uart.v
   fops.v lampFPU_utils.v
   mc14500b.v ttlc_io.v ttlc_fetch.v shift_reg_io.v
}
# Everything is read as SystemVerilog: lisa_core.v and lisa_rx8n.v use size casts.
set generated {debug_regs.v lisa_dbg.v}
foreach f $sources {
   if {$f in $generated} {
      read_verilog -sv $gen/$f
   } else {
      read_verilog -sv $src/$f
   }
}
read_verilog -sv [list $src/lampFPU_div_top.sv $src/lampFPU_div.sv $src/lampFPU_fractDiv.sv]
read_verilog -sv [list $here/fpga_cells.v $here/lisa_arty_clk.v \
   $here/eth_crc32_byte.v $here/eth_mii_mac.v $here/eth_ipstack.v $here/ttlc_eth_app.v $here/eth_ttlc.v \
   $here/ttlc_chains_fpga.v $here/m3_pmod.v $here/lisa_arty.v]
read_xdc $here/lisa_arty.xdc

synth_design -top lisa_arty -part $part -include_dirs $src -generic CLK_DIVIDE=$div
write_checkpoint -force $out/post_synth.dcp
source $here/lisa_arty_mcp.tcl
report_utilization -file $out/util_synth.rpt
opt_design
# the timing-driven directives: the third chip's build at 50 MHz was 0.27 ns
# short on one path that is 71% routing (the BF16 operand classification
# registers -> the adder -> facc), the default directives' placement
place_design -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design -directive Explore
phys_opt_design -directive AggressiveExplore
write_checkpoint -force $out/post_route.dcp
report_timing_summary -file $out/timing.rpt
report_utilization -hierarchical -file $out/util.rpt
report_drc -file $out/drc.rpt
write_bitstream -force $out/lisa_arty.bit

set setup [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set hold  [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "lisa_arty: worst setup slack $setup ns, worst hold slack $hold ns, bitstream $out/lisa_arty.bit"
