# RV32I Pipelined Processor

A 5-stage pipelined RV32I processor in Verilog, targeting the Digilent Basys3 (Artix-7) FPGA.

## Status

Early stage. The building blocks are done:

- `rtl/alu.v`: `simple_alu`, a 32-bit ALU (add, sub, mul, and) with a zero flag
- `rtl/reg32x32_2r.v`: `regfile_32x32_2r`, 32 × 32-bit registers, two asynchronous read ports, one synchronous write port
- `rtl/top_processor.v`: a small FSM that drives the ALU and register file to sum a counter
- `tb/tb_reg32x32.v`: testbench for `top_processor` (loads `tb/init.dat` into the register file)

## Roadmap

- [ ] RV32I decoder and immediate generation
- [ ] 5-stage pipeline (IF / ID / EX / MEM / WB)
- [ ] Forwarding and hazard detection
- [ ] Branches and jumps
- [ ] Verification with riscv-tests and GCC-compiled C programs
- [ ] Run on Basys3
- [ ] Optional: custom INT8 dot-product instruction

## Layout

```
rtl/   synthesizable Verilog
tb/    testbenches and memory init files
```

## Simulate

```bash
make xsim   # Vivado simulator (source settings64.sh first)
make sim    # Icarus Verilog
```

In Vivado, add `rtl/` as design sources and `tb/` as simulation sources. Keep the Vivado project in `vivado/`, which Git ignores.
