# I/O constraints of rv32i_core, shared by DC (core.sdc), ICC2 (apr.sdc) and PrimeTime; needs $cycle and clk.
# The memories are outside the core and combinational (README "Core interface"), so one instruction is a single
# path through both of them: PC -> imem_addr -> instruction -> dmem_addr -> load data -> register file.
# The cycle is budgeted with zero-delay memories: PC to imem_addr 30%, instruction to dmem_addr 30%,
# load data to the registers 40%. An instruction without a load has the last 70% for decode, ALU and write back.
set t_insn [expr {0.3 * $cycle}]
set t_load [expr {0.6 * $cycle}]
set_input_delay  $t_insn -clock clk [get_ports imem_rdata*]
set_input_delay  $t_load -clock clk [get_ports dmem_rdata*]
set_input_delay  0       -clock clk [get_ports rst]
set_output_delay [expr {$cycle - $t_insn}] -clock clk [get_ports imem_addr*]
set_output_delay [expr {$cycle - $t_load}] -clock clk [get_ports dmem_addr*]
# store data and byte enables are written at the clock edge; retire_* (if present) only feed the testbench
set_output_delay 0 -clock clk [remove_from_collection [all_outputs] [get_ports {imem_addr* dmem_addr*}]]
set_load  0.05 [all_outputs]
set_drive 0.1  [remove_from_collection [all_inputs] [get_ports clk]]
