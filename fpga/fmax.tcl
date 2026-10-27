# Fmax and resource report for rv32i_core inside the Basys3 top level (XC7A35T-1CPG236C).
#   vivado -mode batch -source fpga/fmax.tcl -tclargs <program.hex> [core_mhz] [core_rtl...]
# Place and route at CORE_MHZ (keep it above the expected Fmax so the tools push timing), then
# Fmax = 1 / (period - WNS). The core's LUT / FF / DSP / BRAM come from the hierarchical utilization.
# No bitstream. Reports go to build/fmax/; the last line is a one-line summary for make fmax.
set hex      [file normalize [lindex $argv 0]]
set core_mhz [expr {[llength $argv] > 1 ? [lindex $argv 1] : 50}]
set core_rtl [lrange $argv 2 end]
set out build/fmax
file mkdir $out

read_verilog [glob fpga/rtl/*.v]
foreach f $core_rtl { read_verilog $f }
read_xdc fpga/basys3.xdc

synth_design -top basys3_top -part xc7a35tcpg236-1 \
    -generic INIT_FILE="$hex" -generic CORE_MHZ=$core_mhz
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
set core   [get_cells u_core]
set luts   [llength [get_cells -hierarchical -filter "PRIMITIVE_GROUP == LUT && NAME =~ u_core/*"]]
set ffs    [llength [get_cells -hierarchical -filter "PRIMITIVE_GROUP == FLOP_LATCH && NAME =~ u_core/*"]]
set dsps   [llength [get_cells -hierarchical -filter "PRIMITIVE_GROUP == ARITHMETIC && NAME =~ u_core/*"]]
puts [format "FMAX_DONE target=%dMHz WNS=%.3fns fmax=%.1fMHz core_LUT=%d core_FF=%d core_DSP=%d critical=%s->%s" \
    $core_mhz $wns $fmax $luts $ffs $dsps [get_property STARTPOINT_PIN $path] [get_property ENDPOINT_PIN $path]]
