# Fmax and resource report for rv32i_core inside a board's top level (fpga/boards.tcl).
#   vivado -mode batch -source fpga/fmax.tcl -tclargs <board> <program.hex> <core_mhz> <mem_kib> [core_rtl...]
# Place and route at CORE_MHZ (keep it above the expected Fmax so the tools push timing), then
# Fmax = 1 / (period - WNS). The core's LUT / FF / DSP come from the cells under u_soc/u_core.
# No bitstream. Reports go to build/fmax/<board>/; the last line is a one-line summary for make fmax.
# Fmax depends on the part and package: compare boards in separate columns, not as one number.
source fpga/boards.tcl
set board    [lindex $argv 0]
set hex      [file normalize [lindex $argv 1]]
set core_mhz [lindex $argv 2]
set mem_kib  [lindex $argv 3]
set core_rtl [lrange $argv 4 end]
set out      build/fmax/$board
file mkdir $out

read_board_sources $board $core_rtl

synth_design -top [board_get $board top] -part [board_get $board part] \
    -generic INIT_FILE="$hex" -generic CORE_MHZ=$core_mhz -generic MEM_KIB=$mem_kib
opt_design
place_design
phys_opt_design
route_design
report_utilization -hierarchical -file $out/utilization_hier.rpt
report_timing_summary -max_paths 5 -file $out/timing.rpt

set path   [get_timing_paths -max_paths 1 -nworst 1 -setup]
set wns    [get_property SLACK $path]
set period [expr {1000.0 / $core_mhz}]
set fmax   [expr {1000.0 / ($period - $wns)}]
set luts   [llength [get_cells -hierarchical -filter "PRIMITIVE_GROUP == LUT && NAME =~ u_soc/u_core/*"]]
set ffs    [llength [get_cells -hierarchical -filter "PRIMITIVE_GROUP == FLOP_LATCH && NAME =~ u_soc/u_core/*"]]
set dsps   [llength [get_cells -hierarchical -filter "PRIMITIVE_GROUP == ARITHMETIC && NAME =~ u_soc/u_core/*"]]
puts [format "FMAX_DONE board=%s mem=%dKiB target=%dMHz WNS=%.3fns fmax=%.1fMHz core_LUT=%d core_FF=%d core_DSP=%d critical=%s->%s" \
    $board $mem_kib $core_mhz $wns $fmax $luts $ffs $dsps [get_property STARTPOINT_PIN $path] [get_property ENDPOINT_PIN $path]]
