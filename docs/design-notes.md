# Design notes

Longer discussion behind the README: related work, the limits of the instruction-extension approach, when a
loosely-coupled accelerator fits better, and the plan after the core and `dot4` are done.

The numbers below are golden-model instruction counts from the U-Net block benchmark (README, "U-Net block
benchmark"); the single-cycle core should run one instruction per cycle, and the cycle counts will replace them once
the core and the custom instructions are in the RTL.

## Related work

A packed INT8 dot product in a RISC-V core is not a new idea:

- PULP's RI5CY / CV32E40P (Xpulp extension) has packed 8-bit dot-product instructions, including mixed
  unsigned x signed ones; XpulpNN extends them to lower bit widths.
- The draft RISC-V P extension (packed SIMD) has packed 8-bit multiply-accumulate instructions.
- Intel VNNI `vpdpbusd` uses the same u8 x s8 split as `dot4`.
- Google's CFU Playground adds custom function units to a RISC-V core on Artix-7 FPGAs to speed up INT8 TFLite Micro
  models, close to this project's setup.
- BlackParrot (University of Washington) is an open RV64 core that describes itself as a lightweight accelerator
  host: accelerators sit on its on-chip network, and its BedRock system can keep them cache-coherent with the cores.
  It sits further toward the loosely-coupled end than this project.
- Celerity (UCSD, Cornell, UW and Michigan; TSMC 16 nm) is a tiered accelerator fabric: Linux-capable RISC-V
  cores, a 496-core RISC-V manycore and a binarized neural network accelerator generated with high-level synthesis and
  attached to a Rocket core as a custom coprocessor (RoCC). HammerBlade continues its manycore tier.
- OpenPiton (Princeton) is an open manycore research platform with the P-Mesh coherent cache system. Its BYOC
  framework connects any core or accelerator through one narrow handshaked interface (the Transaction-Response
  Interface) and a small per-core transducer.

What this project adds is the link to one workload: the operand signedness of `dot4` and the `requant` format come
from the INT8 version of the U-Net I use for dental X-rays, and the benchmark measures a block of that network,
including the parts after the convolution.

## Limits of the instruction-extension approach

1. **Instruction overhead.** In the `dot4` inner loop, 1 of 7 instructions does arithmetic. The whole `block_nn`
   run does 36,864 MACs in 78,503 instructions, 0.47 MACs per instruction. Accumulating into `rd`,
   post-increment loads and a hardware loop would bring the loop to 3 instructions (2 loads and the `dot4`),
   1.33 MACs per instruction.
2. **Operand bandwidth.** A `dot4` reads two 32-bit registers, so it can do at most 4 MACs, and on a single-issue
   core with one 32-bit load per cycle, a `dot4` whose operands are used only once needs two loads first. Reusing
   operands in registers removes most of those loads: register blocking (`block_rb`, 2 output pixels x 4 output
   channels) loads 6 words for 8 `dot4`s and already reaches 1.28 MACs per instruction in its inner loop with no
   hardware change (25 instructions for 32 MACs; the convolution runs 2.45x fewer instructions than in `block_nn`).
   Larger blocks are limited by the 31 usable registers (P x C accumulators plus P + C operands for a P x C block).
   Going further means wider registers, more ports or local storage in the functional unit (weights or accumulators
   kept inside it), which is where a coprocessor starts.
3. **Memory.** The Basys3 has no DRAM and the core has 8 KiB of program and data memory, so only small tiles fit.
   A full-size U-Net layer does not fit, and at about one MAC per cycle it would also be slow.

## When a loosely-coupled accelerator is the better choice

Accelerators such as NVDLA, Eyeriss or Gemmini let the CPU describe a whole layer and then move the data themselves
(DMA into local buffers) and feed an array of multipliers directly, without going through the register file or
the instruction stream, so they are not limited to the 4 MACs per instruction of `dot4`. They pay for this in
area, a DRAM interface and a less flexible programming model, and they do not fit on a Basys3.

The instruction-extension approach fits when:

- the core is small (microcontroller class) and area matters more than throughput;
- the model is small, or only parts of it need speeding up;
- other work (pre- and post-processing, control) runs on the same core and has to stay programmable.

In this project it also keeps every part of the design my own and small enough to verify fully.

## What the profiling showed

- Speeding up the convolution moves the bottleneck: with `dot4` alone, requantization takes 35% of the block, and
  the `requant` instruction gives a further 1.5x. Deeper layers reduce that share (23% with 64 input channels).
- A general-purpose M extension would recover most of that (`block_mul`), so a custom `requant` is mainly worth it
  on a core without a multiplier.
- Max pooling is under 0.5% of the block, so `max4` is not worth its hardware.

## Ideas taken from BlackParrot and ZynqParrot

Reviewed on 2026-11-20. BlackParrot is far larger than this core (RV64, multicore, Linux, a coherent memory
system), so none of its RTL is used. Four of its design habits fit this project:

1. **Latency-insensitive interfaces to the functional units.** The core talks to `dot4`, `requant` and later units
   through a valid / ready handshake instead of assuming a fixed one-cycle result. The first versions still answer in
   one cycle, but a pipelined multiply-accumulate (for Fmax) or an INT4 or 2:4 unit can then replace a unit without
   changing the pipeline.
2. **Per-instruction comparison with the golden model from the start.** The `retire_*` ports and `RETIRE=1`
   (`make trace`, `make random-test`) compare every retired instruction with `sw/iss.py`. They are used while
   bringing up the core, not added at the end: a failing rv32ui test only says which test failed, while the retire
   trace points at the first wrong instruction.
3. **Configurations as parameters, not branches.** Whether the core has `dot4`, `requant` or the INT4 `dot8` is a
   parameter in the core package, so `make fmax` and the ASIC flow build every configuration from one source tree
   instead of from the `nnops` and `int4` branches.
4. **One test program for simulation and the board (from ZynqParrot).** ZynqParrot runs the same C++ host program
   against an RTL simulator and against a Zynq FPGA, and gates the clock of the design while the host is slow, so
   that the design sees the same cycles in both. The Basys3 has no ARM core, so this project uses a UART bridge
   instead: control and status registers (start, done, cycle count) and a data FIFO, a cycle counter that only counts
   while the core runs, and one host program with a Verilator back end and a UART back end. The board test passes
   when the U-Net block is bit-exact with the golden model and the cycle count matches simulation.

Not taken: BedRock cache coherence, the on-chip network, multicore and Linux support, BlackParrot's front end and
branch prediction. They do not fit a single-core design on a Basys3, and they would make the area and Fmax
comparison harder to read.

## Ideas taken from Celerity and HammerBlade

Reviewed on 2026-11-20. Both are manycore chips, so again no RTL is used.

1. **An HLS-generated accelerator attached to the core (from Celerity).** Celerity's neural network accelerator was
   generated with HLS and attached to a core as a coprocessor. Here, the hls4ml `io_stream` design of the U-Net block
   gets a memory-mapped or streaming wrapper and is attached to this core. That gives the middle point of the coupling
   comparison (see Next steps) from a design that is already bit-exact, instead of a hand-written coprocessor.
2. **Tiers mapped to parts of the workload (from Celerity).** Control, pre- and post-processing stay on the
   programmable core, and the fixed, heavy convolution goes to the accelerator. This is the framing for when each
   approach fits, above ("When a loosely-coupled accelerator is the better choice").
3. **Scratchpads instead of caches (from HammerBlade).** The coprocessor's buffers are scratchpads the core writes
   directly, like the core's own 8 KiB memory, so there is no DMA engine to build.
4. **A reference for a pipelined core (from HammerBlade).** Its Vanilla-5 core is a small 5-stage RV32 core in
   SystemVerilog; it is worth reading for forwarding and hazards if this core is pipelined later, not for copying.

Not taken: the manycore arrays and their on-chip networks, the global address space with remote loads and stores,
the manycore programming model and the Linux-capable cores.

## Ideas taken from OpenPiton

Reviewed on 2026-11-20. No RTL is used.

1. **Energy per instruction.** The Piton chip was characterized for power and energy, down to individual
   instructions (as I recall from the OpenPiton group's HPCA 2018 paper, not checked yet). Here, PrimePower in the
   ASIC flow (`asic/run_asic.sh`) measures post-layout energy for one `dot4` against the base instruction sequence it
   replaces, and for the whole U-Net block. The coupling comparison then reports energy per MAC as well as cycles and
   area. Only the ASIC flow gives this number; FPGA power estimates for the hls4ml designs are not accurate enough to
   put next to it.
2. **One handshaked interface plus small transducers, outside the core (from BYOC).** The core's own memory port
   stays as it is (a single-cycle core would need stall logic for a handshake). The bus outside the core uses one
   request / response handshake, and the BRAM, the UART bridge for the board test and later the hls4ml coprocessor
   each get a small transducer to it, so attaching the coprocessor does not mean rebuilding the bus. This is the
   memory-side counterpart of the valid / ready interfaces to the functional units.
3. **A data-supply unit decoupled from compute (as I recall from MAPLE, Princeton's decoupled access engine on
   OpenPiton, not checked yet).** A small unit that fetches `dot4` operands ahead of time would remove the two loads
   in front of each `dot4` (see "Limits of the instruction-extension approach"). An untested idea, to compare with the
   accumulating `dot4` and post-increment loads.

Not taken: the P-Mesh coherence system and its on-chip networks, the manycore, the OpenSPARC and Ariane cores, Linux,
heterogeneous-ISA support, and OpenPiton's test infrastructure (this project already has the golden model, random
tests and CI).

## Next steps

- Cycle counts, LUT / FF / DSP and Fmax on the Basys3 with and without each instruction.
- An accumulating `dot4` and post-increment loads, to measure how much of the 7-to-3 instruction reduction is real.
  Both need compiler support to be used from C (see below).
- Compiler support in LLVM's RISC-V backend, in steps:
  1. Assembler and disassembler support, so that `dot4`, `max4` and `requant` can be written and are shown by
     their names instead of `.insn`.
  2. An intrinsic for each instruction, defined with TableGen and selected by the backend, replacing the inline
     assembly in `sw/c/dot4.h` and `sw/c/nnops.h`.
  3. Code generation for the post-increment loads and the accumulating `dot4`, so that the inner loop written with
     the intrinsic compiles to the shorter sequence; then the U-Net block benchmark measures the hardware and
     compiler changes together.
  4. (Harder, later) recognizing the plain C byte-wise multiply-accumulate loop and turning it into `dot4` without
     an intrinsic.
- A coupling comparison on the same U-Net block (`head.0.block.3`, real weights), with three points:
  1. tightly coupled: custom instructions in the core (`dot4`, `requant`);
  2. loosely coupled: the same hls4ml `io_stream` design behind a memory-mapped or streaming wrapper, attached to
     the core as a coprocessor with scratchpad buffers (not built yet);
  3. standalone dataflow: the hls4ml `io_stream` design on its own (`docs/hls4ml-baseline.md` on the `hls4ml`
     branch).
  Points 2 and 3 use the same hls4ml design, so their difference is the cost of attaching it to a CPU (data movement
  and control); points 1 and 2 compare custom instructions with a coprocessor. Each point is measured for cycles,
  LUT / FF / DSP and Fmax, for how much of the network it can run without new hardware, and, for points 1 and 2
  through the ASIC flow, for energy per MAC (PrimePower). A hand-written 3x3
  convolution coprocessor with its own line buffer can be added later to compare hand-written RTL with HLS. Planned
  for after January 2027; the UART bridge and control registers from the board test can be reused.
- Gemmini in simulation (Chipyard) as a reference point for the loosely-coupled end.
