# RV32I Pipelined Processor

A 5-stage pipelined RV32I processor in Verilog, targeting the Digilent Basys3 (Artix-7) FPGA.

## Status

Early stage. The building blocks are done:

- `rtl/alu.v`: `simple_alu`, a 32-bit ALU (add, sub, mul, and) with a zero flag
- `rtl/reg32x32_2r.v`: `regfile_32x32_2r`, 32 × 32-bit registers, two asynchronous read ports, one synchronous write port
- `rtl/top_processor.v`: a small FSM that drives the ALU and register file to sum a counter
- `tb/tb_reg32x32.v`: testbench for `top_processor` (loads `tb/init.dat` into the register file)

The verification setup is ready: the riscv-tests rv32ui suite builds and runs against `rv32i_core` with `make test` (see below).

## Roadmap

- [x] Verification setup: riscv-tests (rv32ui) on a bare-metal test environment, testbench, CI
- [ ] Single-cycle RV32I core that passes rv32ui
- [ ] RV32I decoder and immediate generation
- [ ] 5-stage pipeline (IF / ID / EX / MEM / WB)
- [ ] Forwarding and hazard detection
- [ ] Branches and jumps
- [x] C runtime and test programs; Basys3 top level, memory-mapped I/O and build script (checked with a stand-in core)
- [ ] GCC-compiled C programs running on the core
- [ ] Run on Basys3
- [ ] Optional: custom INT8 dot-product instruction

## Layout

```
rtl/                 synthesizable Verilog
tb/                  testbenches and memory init files
sw/env/              bare-metal riscv-tests environment (riscv_test.h, link.ld)
sw/c/                C runtime (crt0.S, link.ld, mmio.h) and test / demo programs
sw/                  hex conversion and test runner scripts
fpga/                Basys3 top level, memory, 7-segment driver, XDC, Vivado build script
third_party/         riscv-tests (git submodule)
```

After cloning, fetch the tests with `git submodule update --init` (not `--recursive`; the tests' own `env` submodule is not used).

## Core interface

`tb/tb_core.v` instantiates a module named `rv32i_core` with these ports:

| Port | Dir | Width | Meaning |
| --- | --- | --- | --- |
| `clk` | in | 1 | clock |
| `rst` | in | 1 | synchronous reset, active high; the core starts fetching at PC = 0 |
| `imem_addr` | out | 32 | instruction address (the PC) |
| `imem_rdata` | in | 32 | instruction at `imem_addr`, combinational |
| `dmem_addr` | out | 32 | data address (byte address; the memory uses bits [15:2]) |
| `dmem_wdata` | out | 32 | store data, already shifted to the byte lanes selected by `dmem_wstrb` |
| `dmem_wstrb` | out | 4 | byte write enables; `4'b0000` = no store. Written on the rising clock edge |
| `dmem_rdata` | in | 32 | the aligned word at `dmem_addr`, combinational; the core picks and extends bytes / halfwords for loads |

The core has to treat `FENCE` as a no-op; no CSRs, traps or `ECALL` are needed.

## Memory map

| Address | Simulation (`tb/tb_core.v`) | Basys3 (`fpga/rtl/basys3_top.v`) |
| --- | --- | --- |
| `0x0000_0000` | RAM, 64 KiB | RAM, 8 KiB (distributed RAM), loaded from the program hex at configuration |
| `0x8000_0000` TOHOST | store ends the run: 1 = pass, `(n << 1) \| 1` = fail n | store is latched and shown on the 7-segment display; LED15 lights |
| `0x8000_0004` LED | store is logged | write `LED[15:0]` |
| `0x8000_0008` SEG | store is logged | write a 16-bit value, shown as 4 hex digits |
| `0x8000_000C` SW | reads 0 | read `SW[15:0]` (two-flop synchronized) |

C programs link for 8 KiB (`sw/c/link.ld`) so the same hex runs in simulation and on the board.

## C programs

`sw/c/crt0.S` sets `gp` and `sp`, clears `.bss`, calls `main` and stores its return value to TOHOST
(0 = pass). Multiply and divide come from libgcc (`__mulsi3`, `__divsi3`), since RV32I has no M extension.

```bash
make c-test                # sum, fib, sort, muldiv: each returns 0 when its result is correct
make c-one P=fib VCD=1     # one program; disassembly in build/c/fib.dump
```

## Basys3

```bash
source /Xilinx/2025.2.1/Vivado/settings64.sh
make bit P=demo            # build/fpga/basys3_top.bit, timing in build/fpga/timing.rpt
make bit P=demo MHZ=50     # core clock from the MMCM: 25 (default) or 50 MHz
```

`demo.c` shows fib(`SW[4:0]`) in hex on the display and a counter on the LEDs. BTNC is reset.
Program the board with the Vivado Hardware Manager (on Windows if WSL cannot see the USB cable).
The memory reads are asynchronous (core interface above), so the RAM is distributed RAM, not block RAM.

## Test

```bash
make selftest              # testbench check with a stand-in core (tb/selftest_core.v)
make test                  # build rv32ui and run every test, prints "N / 40 passed"
make test-one T=add VCD=1  # one test, waveform in build/add.vcd; disassembly in build/tests/add.dump
```

A failing test prints the riscv-tests case number (`FAIL add: test case 7`); look for `test_7` in `build/tests/add.dump`.
Tools in WSL: `sudo apt install iverilog gcc-riscv64-unknown-elf`. CI runs the same steps on every push.

The top_processor demo:

```bash
make xsim   # Vivado simulator (source settings64.sh first)
make sim    # Icarus Verilog
```

In Vivado, add `rtl/` as design sources and `tb/` as simulation sources. Keep the Vivado project in `vivado/`, which Git ignores.
