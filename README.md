# RV32I Processor with a Custom INT8 Dot-Product Instruction

A single-cycle RV32I processor in Verilog for the Digilent Basys3 (Artix-7) FPGA, extended with `dot4`, a custom
instruction that does four INT8 multiply-accumulates. The benchmark is the inner loop of an INT8 convolution from
the U-Net I use in my dental-imaging research.

## Status

Work in progress: the core (`rtl/rv32i_core.v`) is not written yet. The building blocks are done:

- `rtl/alu.v`: `simple_alu`, a 32-bit ALU (add, sub, mul, and) with a zero flag
- `rtl/reg32x32_2r.v`: `regfile_32x32_2r`, 32 × 32-bit registers, two asynchronous read ports, one synchronous write port
- `rtl/top_processor.v`: a small FSM that drives the ALU and register file to sum a counter
- `tb/tb_reg32x32.v`: testbench for `top_processor` (loads `tb/init.dat` into the register file)

The verification setup is ready: the riscv-tests rv32ui suite builds and runs against `rv32i_core` with `make test` (see below).

## Roadmap

- [x] Verification setup: riscv-tests (rv32ui) on a bare-metal test environment, testbench, CI
- [x] Golden model (instruction-set simulator) with per-instruction trace comparison
- [x] C runtime and test programs; Basys3 top level, memory-mapped I/O and build script (checked with a stand-in core)
- [ ] Single-cycle RV32I core: decoder, immediates, branches and jumps, loads and stores; passes rv32ui
- [ ] GCC-compiled C programs running on the core
- [ ] `dot4` in the core: golden model, tests and convolution benchmark ready; RTL to do
- [ ] Cycle counts, LUT / FF / DSP and Fmax with and without `dot4`
- [ ] Run the `dot4` convolution on the Basys3
- [ ] Optional: 5-stage pipeline with forwarding and hazard detection

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

## Golden model and trace comparison

`sw/iss.py` is an RV32I instruction-set simulator with the same memory map as the testbench.
`make trace` runs a program on the core and on the simulator and reports the first place they differ:

```bash
make iss-test              # every test and C program on the simulator alone (all should pass)
make trace T=add           # compare stores; works with any core
make trace P=fib RETIRE=1  # also compare every retired instruction (needs the ports below)
```

A mismatch prints the instructions before it, the expected and actual result, and a hint
(wrong PC: branch, flush or stall; wrong value: ALU, immediate or forwarding).
Traces are in `build/trace/<name>.ref` (simulator) and `<name>.core` (core).

For `RETIRE=1` the core adds these output ports, driven once per instruction as it completes
(in program order; in a pipeline, from the WB stage). The testbench connects them only when built
with `-DRETIRE_TRACE`, so a core with them still works with `make test`.

| Port | Width | Meaning |
| --- | --- | --- |
| `retire_valid` | 1 | an instruction completes this cycle (not a bubble or a flushed instruction) |
| `retire_pc` | 32 | its PC |
| `retire_insn` | 32 | its instruction word |
| `retire_rd` | 5 | the register it writes, or 0 if none (stores, branches, `FENCE`) |
| `retire_rd_wdata` | 32 | the value written to `retire_rd` |

The run ends at the TOHOST store, so a pipelined core's trace may be up to 4 instructions short; that still counts as a match.

The top_processor demo:

```bash
make xsim   # Vivado simulator (source settings64.sh first)
make sim    # Icarus Verilog
```

In Vivado, add `rtl/` as design sources and `tb/` as simulation sources. Keep the Vivado project in `vivado/`, which Git ignores.

## dot4 custom instruction

`dot4 rd, rs1, rs2` multiplies the four byte lanes of `rs1` and `rs2` and writes the sum to `rd`.
Encoding: custom-0 opcode `0001011`, R-type, funct3 = 0, funct7 = 0. `rs1` lanes are unsigned (u8 activations)
and `rs2` lanes signed (s8 weights): in the OpenVINO INT8 version of the U-Net, the activations entering every
convolution except the first are unsigned and the weights are symmetric INT8, the same split as Intel VNNI
`vpdpbusd`. `make ... DOT4_ACT=signed` builds the programs for s8 x s8 instead (also flip `DOT4_RS1_SIGNED`
in `sw/iss.py`).
Whether to accumulate into `rd`, saturate, or use DSP48 slices is still open.

| Target | What it runs |
| --- | --- |
| `make dot4-iss` | `dot4_test`, `conv_ref`, `conv_dot4` on the golden model with `--dot4` |
| `make dot4-test` | `dot4_test` and `conv_dot4` on `rv32i_core` (needs dot4 in the RTL) |
| `make bench` | cycles on the core and instructions on the golden model for each version |

- `sw/c/dot4.h`: `dot4()` through GCC's `.insn r 0x0B, 0, 0, ...` (no compiler change) and the plain C `dot4_ref()`.
- `sw/c/bench/dot4_test.c`: 64 edge-value pairs and 64 pseudo-random pairs against `dot4_ref()`.
- `sw/c/bench/conv.c`: one INT8 3x3 convolution tile in HWC layout (32 input channels, 2x2 outputs, 4 output
  channels, 4,608 MACs; data and checksum from `sw/c/gen_conv.py`), built three ways: plain RV32I (`conv_ref`,
  products through `__mulsi3`), RV32IM (`conv_mul`, golden model only, as a fair baseline with a hardware
  multiplier) and dot4 (`conv_dot4`, 32-bit loads, four MACs per instruction).

Golden-model instruction counts (2026-10-27): `conv_ref` 554,542, `conv_mul` 33,779, `conv_dot4` 9,587,
so dot4 executes 3.5x fewer instructions than RV32IM and 58x fewer than plain RV32I. Cycle counts on the core
come from `make bench` once dot4 is in the RTL.

## Credits

The ALU, register file and control FSM in `rtl/` are my own, and the core and the `dot4`
RTL will be. The verification environment (`tb/tb_core.v`, `sw/`, CI), the golden model, the C runtime and test
programs, the Basys3 top level and build scripts (`fpga/`), and the `dot4` tests and benchmark were written with an
AI assistant (Claude).
