# rv32i_core APR constraints (ICC2); run_asic.sh sets the cycle
# DC-only commands (wire load, operating conditions, set_fix_hold, ideal network) removed; ICC2 uses TLU+
# parasitics and propagated clocks after CTS. Hold is fixed 0.05 ns past the 0.1 ns PrimeTime signs off with.
set cycle 10.0
create_clock -name clk -period $cycle [get_ports clk]
set_clock_uncertainty 0.1 [all_clocks]
set_clock_uncertainty -hold 0.15 [all_clocks]
source pt_io.sdc
set_max_fanout 20 [all_inputs]
