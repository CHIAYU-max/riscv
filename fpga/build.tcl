# Non-project Vivado build for Basys3 (XC7A35T-1CPG236C).
#   vivado -mode batch -source fpga/build.tcl -tclargs <program.hex> [core_mhz] [core_rtl...]
# Run from the repo root. Reports and the bitstream go to build/fpga/.
set hex      [file normalize [lindex $argv 0]]
set core_mhz [expr {[llength $argv] > 1 ? [lindex $argv 1] : 25}]
set core_rtl [lrange $argv 2 end]
set out build/fpga
file mkdir $out

read_verilog [glob fpga/rtl/*.v]
foreach f $core_rtl { read_verilog $f }
read_xdc fpga/basys3.xdc

synth_design -top basys3_top -part xc7a35tcpg236-1 \
    -generic INIT_FILE="$hex" -generic CORE_MHZ=$core_mhz
report_utilization -file $out/utilization_synth.rpt
opt_design
place_design
route_design
report_utilization    -file $out/utilization.rpt
report_timing_summary -file $out/timing.rpt
write_bitstream -force $out/basys3_top.bit

# One-line summary for the terminal
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "BUILD_DONE core=${core_mhz}MHz WNS=${wns}ns bit=$out/basys3_top.bit"
