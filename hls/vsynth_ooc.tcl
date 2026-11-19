# Vivado out-of-context synthesis of one hls4ml project with a 100 MHz clock on ap_clk, for LUT / FF / DSP / BRAM
# and timing (hls4ml's own vivado_synth.tcl has no clock constraint, so it gives no Fmax).
# usage (inside a project directory): vivado -mode batch -source ../vsynth_ooc.tcl
set project_name unet_block
set part xc7a35tcpg236-1
read_verilog [glob ${project_name}_prj/solution1/syn/verilog/*.v]
foreach f [glob -nocomplain ${project_name}_prj/solution1/syn/verilog/*.dat] { file copy -force $f . }
set xdc [open vsynth_clock.xdc w]
puts $xdc "create_clock -period 10.000 -name ap_clk \[get_ports ap_clk\]"
close $xdc
read_xdc -mode out_of_context vsynth_clock.xdc
synth_design -top $project_name -part $part -mode out_of_context
opt_design
report_utilization -file vsynth_util.rpt
report_timing_summary -file vsynth_timing.rpt
