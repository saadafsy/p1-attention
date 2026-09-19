# Program a bitstream into the Nexys A7 over JTAG/USB (Vivado hardware manager).
# Usage: vivado -mode batch -source fpga/scripts/program.tcl -tclargs <bitfile>
# UNVERIFIED: written without Vivado or a board.
if {$argc != 1} { puts "usage: program.tcl <bitfile>"; exit 1 }
set bit [lindex $argv 0]
if {![file exists $bit]} { puts "ERROR: $bit not found"; exit 1 }
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a100t*] 0]
if {$dev eq ""} { puts "ERROR: no xc7a100t device found on the JTAG chain"; exit 1 }
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "programmed $bit into [get_property PART $dev]"
close_hw_manager
exit 0
