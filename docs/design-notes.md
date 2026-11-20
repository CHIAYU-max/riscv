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
- Chipyard (Berkeley) is a Chisel SoC generator with Rocket and BOOM cores, the TileLink bus, RoCC custom
  coprocessors (Gemmini among them), FireSim for FPGA-accelerated simulation and Hammer for the VLSI flow.
- Chiplet Cloud (University of Washington) designs chiplet-based ASICs for serving large language models, with a
  two-phase hardware / software design-space search judged on one metric, total cost of ownership per generated
  token. ReaLLM, from the same group, is a simulation framework that links accelerator-level detail to system-level
  LLM serving performance.
- PRGA (Princeton) generates custom FPGA fabrics; the CIFER chip used it for an embedded FPGA attached to OpenPiton's
  P-Mesh as a reconfigurable accelerator. CGRAs (coarse-grained reconfigurable arrays) sit between FPGAs and fixed
  accelerators: arrays of word-level processing elements whose functions and connections are set by configuration
  registers (for example Cornell's UE-CGRA and Stanford's Canal interconnect generator).
- Ang Li's group at the University of Washington (PRGA's author): Duet (HPCA 2023) makes embedded FPGAs cache-coherent
  peers of the cores; DICE (ISCA 2026) replaces a GPU's SIMD back end with statically scheduled CGRAs to cut
  register-file accesses; MFSA (ICCD 2026) is a multi-format systolic array whose processing elements share one
  datapath from FP32 down to INT4, including block-scaled formats; CacheFlex (MICRO 2026) lets software turn part of
  the private L2 into a scratchpad at run time.

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

## Ideas taken from Chipyard

Reviewed on 2026-11-20. Neither Chipyard nor Chisel is used.

1. **One register table for the RTL and the C header.** Chipyard's MMIO peripherals describe their registers in one
   declarative map that generates the register hardware. Here, a small Python script reads one table of the board-test
   registers (start, done, cycle count, FIFO addresses) and writes both the SystemVerilog register decoder and the C
   header that the host program uses with both back ends (Verilator and UART). The addresses in the RTL and in the
   host program then cannot disagree, and the coprocessor later adds rows to the same table. The same table also gives
   the address ranges of the transducers on the bus outside the core.
2. **A RoCC-style command interface as a variant of the coprocessor.** RoCC sends commands to an accelerator as custom
   instructions (funct7 and two source registers, optionally writing `rd`), and the accelerator reaches memory through
   its own port. `dot4` already uses custom-0, so point 2 of the coupling comparison can be attached in two ways:
   (a) memory-mapped registers; (b) RoCC-style, with the core issuing custom instructions and the coprocessor reading
   and writing its scratchpads directly. The difference between (a) and (b) is the cost of issuing commands. (a)
   comes first; (b) is optional.
3. **Design, tool and process settings kept apart (from Hammer).** `asic/run_asic.sh` reads one design file (top
   module, file list, clock), so the same script runs the core with and without `dot4` and later the hls4ml
   coprocessor. This matters mainly for the energy comparison of several designs.

Not taken: Chisel, TileLink, the Rocket and BOOM cores, Linux, FireSim (the same idea as ZynqParrot, already taken),
Config mixins (the same as configurations as parameters, already taken) and Spike co-simulation (the golden model and
the retire comparison already do this).

## Ideas taken from ReaLLM and Chiplet Cloud

Reviewed on 2026-11-20. Both target LLM serving in the cloud, so only their methods apply here.

1. **From one measured block to a whole panoramic X-ray (from ReaLLM).** Only `head.0.block.3` can be measured, and a
   full U-Net does not fit on the Basys3. A per-layer cost model is calibrated on the measured block (one set of
   parameters each for the custom instructions, the coprocessor and hls4ml) and summed over the U-Net's layers, giving
   latency and energy per panoramic X-ray for each coupling point. These connect to the measured stage-2 time of the
   dental deployment pipeline. The dental project's analytic 64 x 64 array model is the starting point.
2. **One final metric and a small design-space sweep (from Chiplet Cloud).** The comparison reports cycles, area,
   Fmax and energy, but is judged on one metric, such as energy per panoramic X-ray or area x latency per X-ray. The
   cost model sweeps a few parameters (`dot4` width 4 or 8, the coprocessor's number of multipliers, the hls4ml reuse
   factor); measured points calibrate and check the model, and the other points are estimates and are marked as such.
   This answers which coupling point is best under a given area budget.
3. **Weights in on-chip SRAM, and 2:4 for capacity (untested idea).** Chiplet Cloud keeps all weights in on-chip
   SRAM, so there is no DRAM bandwidth limit (and, as I recall, stores them compressed to fit more; not checked yet).
   2:4 sparsity gave no speedup on the CPU or in hls4ml `io_stream`, but it may still shrink the weights enough for
   a DRAM-less edge chip. To check: the SRAM area for the INT8 weights of the dental U-Net's slim decoder, with and
   without 2:4 storage, from the SOC process's memory data.

Not taken: chiplet packaging, rack and server design, cloud serving, LLM-specific parts (KV cache, batching, token
generation) and cost in money (energy or latency per X-ray fits an edge medical device better).

## Ideas taken from Gemmini

Reviewed on 2026-11-20. Gemmini itself stays an optional reference for the loosely-coupled end (Next steps); these
details shape the coprocessor of the coupling comparison and the cost model.

1. **Post-processing on the way out of the accumulator.** Gemmini's array only multiplies; scaling, ReLU and pooling
   are applied while results are moved out, without going back to the CPU. The coprocessor does requant (the dental
   fixed-point spec: 32-bit accumulator, 16-bit multiplier, one rounding) and ReLU on its read-out path. With `dot4`
   alone, requant takes 35% of the block, so leaving it to the core would hide the coprocessor's gain; the hls4ml
   design already folds it into a BatchNorm, so this also keeps the comparison fair.
2. **Two scratchpads.** 8-bit inputs and weights in one, 32-bit partial sums in an accumulator memory, each with its
   own address range in the register table.
3. **Tiling computed from the hardware parameters.** Gemmini's C library picks tile sizes from the array and
   scratchpad sizes (for example `tiled_conv_auto`). Here, one tiling function reads the hardware-parameter header
   generated from the register table and splits U-Net layers larger than the 8 KiB memory into tiles that fit. The
   per-layer cost model uses the same function, so estimated and measured runs tile the same way.
4. **Counting what is not accelerated.** Speeding up the matrix multiply makes the rest the bottleneck (as I recall,
   Gemmini added im2col and pooling hardware for this reason; not checked yet). The cost model and the comparison
   table include the parts that stay on the core, as the profiling already does (requant 35%, `max4` under 0.5%).
5. **A small parameterized systolic array (optional).** If the coprocessor is later hand-written, it can be a small
   weight-stationary array (for example 4 x 4) instead of the 3 x 3 line-buffer design, so the array size becomes a
   parameter of the design-space sweep and links to the dental project's 64 x 64 analytic model.
6. **Overlapping data movement and compute (later).** As I recall, Gemmini has separate load, store and execute
   controllers (not checked yet). The simplest version here is a double-buffered scratchpad, decided only after the
   first coprocessor shows how much data movement costs.

Not taken: Chipyard integration, TileLink DMA, virtual memory and the TLB, the ONNX Runtime port, Gemmini's Spike
functional model (the golden model does this).

## Ideas taken from FireSim

Reviewed on 2026-11-20. FireSim's main idea, target cycles that do not depend on the host, is already taken from
ZynqParrot (the gated cycle counter). Its on-FPGA instrumentation adds three ideas, built on the register table and
the UART bridge:

1. **A retire signature on the board (after TracerV).** TracerV streams the instruction trace out of the FPGA. The
   UART is too slow for a full trace, so the board instead folds every retired write-back value into a signature (for
   example a CRC) that is read out at the end and compared with the one the golden model computes. A bit-exact output
   does not prove that every instruction was right; the signature also catches errors that only appear on the FPGA,
   such as BRAM initialization or timing problems.
2. **Event counters (after AutoCounter).** Besides the cycle counter: `dot4` instructions executed, loads and
   stores, and cycles spent waiting on the bus handshake, each a row in the register table. The per-layer cost model is
   calibrated from these board counts instead of from golden-model estimates only.
3. **A DRAM latency model (after FASED, later).** A configurable delay in the bus transducer emulates weights held in
   DRAM, so the three coupling points can be compared with weights on chip and in DRAM, which links to the on-chip
   capacity question for 2:4.

Not taken: cloud FPGAs, Chisel / FIRRTL and the Golden Gate compiler (the core is SystemVerilog, and the gated clock
already does the decoupling), datacenter network simulation, Linux, FirePerf (the golden model already profiles
by phase).

## Ideas taken from PRGA and CGRAs

Reviewed on 2026-11-20.

- **PRGA: not taken.** The Basys3 already is an FPGA, so an FPGA fabric inside it adds nothing, and an embedded FPGA
  in the ASIC flow costs far more area than the accelerator it would host. It only marks the most flexible end of the
  reconfigurability range in related work.
- **Configurable processing elements (from CGRAs, optional).** The coprocessor's processing elements get a few modes
  set by configuration registers (multiply-accumulate, maximum, requant with ReLU), so one coprocessor runs
  convolution, pooling and requantization without separate hardware for each. The configuration registers are rows in
  the register table. This improves the "how much of the network runs without new hardware" column, and it is an
  optional variant next to the small systolic array.
- **A second axis for the comparison.** The coupling comparison then has two axes, how tightly the accelerator is
  coupled to the core and whether it can be reconfigured: the fixed hls4ml design, a fixed coprocessor, a
  configurable coprocessor and the custom instructions in the core. The question becomes how much flexibility pays
  off for edge inference on medical images.

Not taken: a full CGRA with its mapping compiler (scheduling and routing onto the array), which is research-level
work, and building or embedding any FPGA fabric.

## Ideas taken from OpenTitan

Reviewed on 2026-11-20. OpenTitan is a silicon root of trust, so none of its hardware applies; its engineering
methods do.

1. **A testplan and coverage, not only passing tests.** Every OpenTitan block has a testplan that maps features to
   tests, and coverage shows what was missed. Here, `docs/testplan.md` maps each instruction group, the `dot4` edge
   cases and every register in the register table to rv32ui, the random tests or `dot4-test`, and Verilator's
   `--coverage` reports line and toggle coverage of the core, listing what no test reaches.
2. **Formal checks through RVFI (via Ibex).** OpenTitan's Ibex core supports the RISC-V Formal Interface (RVFI) from
   YosysHQ's riscv-formal. The core's `retire_*` ports stay as they are; a wrapper maps internal signals to RVFI
   (including rs1 / rs2 values and memory address and masks), and riscv-formal with SymbiYosys checks the core
   against RV32I. How long the checks take on this core has to be tried. Random tests find bugs by sampling; formal
   checks cover every input within their bound, so the two complement each other.
3. **lowRISC's SystemVerilog style guide, with Verible.** New RTL follows its naming (`_i` / `_o` ports, `_d` / `_q`
   for the next and current value of a register), and `make format` and a Verible lint run next to the Verilator
   lint. Existing files are not renamed before the core is finished.
4. **Register descriptions in the style of reggen.** OpenTitan's reggen turns an hjson register description into
   SystemVerilog, a C header and documentation. reggen itself is tied to OpenTitan's TL-UL bus, so the register
   table here uses a similar hjson format and its own small script, which also writes a markdown register map for
   the README.

Not taken: the security blocks (cryptography, key management, side-channel countermeasures) and secure boot, the
TL-UL bus, the UVM environment (it needs a commercial simulator; the golden model and random tests cover this
project's scale), and Ibex as the core (it is a reference to read, next to HammerBlade's Vanilla-5).

## Ideas taken from Duet, DICE, MFSA and CacheFlex

Reviewed on 2026-11-20 from the papers' abstracts; the full papers are still to be read.

1. **One datapath for INT8 and INT4 (from MFSA).** MFSA's processing elements share one datapath across formats, with
   throughput growing as the width shrinks. Here, one dot-product unit runs both `dot4` (four u8 x s8 products) and
   `dot8` (eight u4 x s4 products) instead of two separate units, and the INT4 mode is a core-package parameter, so the
   area cost of adding it is measured directly. The golden-model `dot8` already exists (1.71x to 1.76x fewer
   instructions than the INT8 block), and the dental U-Net passes W4A8 quantization-aware training, so the condition
   set earlier for writing the `dot8` RTL is met. Block-scaled (MX-style) quantization of the dental model, compared
   with the current per-channel fixed point, is a later experiment.
2. **Communication first, then applications (from Duet).** Duet measures processor-accelerator latency and bandwidth
   with synthetic benchmarks before running applications. Here, a microbenchmark measures the core-to-coprocessor
   round trip (start to done) and the cost per transferred word with the event counters, so the gap between coupling
   points 2 and 3 splits into latency and bandwidth.
3. **Energy split by structure (from DICE).** DICE's gain comes from avoiding register-file accesses. The PrimePower
   measurement reports energy for the register file, the ALU / `dot4` unit and memory separately; a large
   register-file share is the measured case for an accumulating `dot4`, an internal accumulator or a coprocessor.
4. **One SRAM, two roles (from CacheFlex, later).** A partition register in the register table splits the 8 KiB data
   memory between core data and the coprocessor's scratchpad, so tiles can grow while the coprocessor runs.

Not taken: embedded FPGAs and coherent integration (Duet), GPUs, SIMT and the CGRA mapping compiler (DICE), floating
point formats and FP32 accumulation (MFSA; the dental model holds its accuracy in integer fixed point), out-of-order
pipelines and OS support (CacheFlex). CHIALU (an ALU generation and optimization library, A3 workshop 2026) has no
public abstract yet; if it is released, a generated unit could serve as a comparison point for the hand-written
`dot4`, which stays hand-written.

## Reused components

Decided on 2026-11-20. The core and the custom-instruction units (`dot4`, `requant`, `max4`) are written from
scratch. Infrastructure outside the core may reuse BaseJump STL (Bespoke Silicon Group, Solderpad Hardware License
0.51), pinned as a git submodule: FIFOs for the UART bridge, counters for the cycle and event counters, an arbiter
for the bus outside the core, and later synchronous memories for the coprocessor's scratchpads. Its modules follow
the same valid / ready and valid / yumi handshakes as this project's interfaces. Checked on 2026-11-20 with
`bsg_fifo_1r1w_small`, `bsg_round_robin_arb` and `bsg_counter_clear_up`: Verilator 5.020 lints them cleanly, and
Icarus Verilog 12 compiles and simulates them with `-gno-assertions` (it does not support their deferred
assertions). Not used: the network-on-chip, cache, DRAM controller, links and process-specific hardened memories.

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
  convolution coprocessor with its own line buffer can be added later to compare hand-written RTL with HLS. A
  per-layer cost model calibrated on these points extends them to latency and energy per panoramic X-ray and to a
  small design-space sweep under one final metric (see "Ideas taken from ReaLLM and Chiplet Cloud"). Planned
  for after May 2027; the UART bridge and control registers from the board test can be reused.
- Gemmini in simulation (Chipyard, Verilator) as a reference point for the loosely-coupled end, run on the same
  convolution layer for cycle counts. Optional and only if a paper or the SOP needs it: the install is large (many GB
  and a conda environment, with 10 GB of memory in WSL), and it is not this project's own design.
