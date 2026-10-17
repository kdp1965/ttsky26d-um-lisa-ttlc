# Programs the Arty connected to this machine with build/lisa_arty.bit
# (volatile: a power cycle clears it).  make prog
set here [file dirname [file normalize [info script]]]
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a35t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $here/build/lisa_arty.bit $dev
program_hw_devices $dev
puts "lisa_arty: programmed [get_property PART $dev]"
close_hw_manager
