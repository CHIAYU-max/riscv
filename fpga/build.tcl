# Non-project Vivado build for one board of fpga/boards.tcl (basys3, nexys_a7).
#   vivado -mode batch -source fpga/build.tcl -tclargs <board> <program.hex> <core_mhz> <mem_kib> [core_rtl...]
# Run from the repo root (make bit BOARD=... does). Reports and the bitstream go to build/fpga/<board>/.
source fpga/boards.tcl
set board    [lindex $argv 0]
set hex      [file normalize [lindex $argv 1]]
set core_mhz [lindex $argv 2]
set mem_kib  [lindex $argv 3]
set core_rtl [lrange $argv 4 end]
set top      [board_get $board top]
set out      build/fpga/$board
file mkdir $out

read_board_sources $board $core_rtl

synth_design -top $top -part [board_get $board part] \
    -generic INIT_FILE="$hex" -generic CORE_MHZ=$core_mhz -generic MEM_KIB=$mem_kib
report_utilization -file $out/utilization_synth.rpt
opt_design
place_design
route_design
report_utilization    -file $out/utilization.rpt
report_timing_summary -file $out/timing.rpt
write_bitstream -force $out/$top.bit

# One-line summary for the terminal
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "BUILD_DONE board=$board core=${core_mhz}MHz mem=${mem_kib}KiB WNS=${wns}ns bit=$out/$top.bit"
