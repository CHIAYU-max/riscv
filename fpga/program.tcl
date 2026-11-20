# Program a board of fpga/boards.tcl over JTAG with the bitstream from build.tcl (volatile: lost at power-off).
#   vivado -mode batch -source fpga/program.tcl -tclargs <board>
# Run from the repo root (make prog BOARD=... does). Fails if the board's FPGA is not on the JTAG chain.
source fpga/boards.tcl
set board [lindex $argv 0]
set bit   build/fpga/$board/[board_get $board top].bit
proc fail {msg} { puts "PROGRAM_ERROR $msg"; exit 1 }
if {![file exists $bit]} { fail "$bit not found: run make bit BOARD=$board first" }

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices [board_get $board dev]*] 0]
if {$dev eq ""} {
    fail "no [board_get $board dev] on the JTAG chain (found: [get_hw_devices]); wrong board or BOARD?"
}
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "PROGRAM_DONE board=$board device=$dev bit=$bit"
close_hw_target
disconnect_hw_server
close_hw_manager
