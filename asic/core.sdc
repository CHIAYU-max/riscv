# rv32i_core synthesis constraints (Design Compiler); run_asic.sh sets the cycle
set cycle 10.0
create_clock -name clk -period $cycle [get_ports clk]
set_dont_touch_network [all_clocks]
set_fix_hold           [all_clocks]
set_clock_uncertainty  0.1 [all_clocks]
set_clock_latency      0.5 [all_clocks]
set_ideal_network      [get_ports clk]
source pt_io.sdc
set_operating_conditions -max_library slow -max slow
set_wire_load_model -name tsmc13_wl10 -library slow
set_max_fanout 20 [all_inputs]
