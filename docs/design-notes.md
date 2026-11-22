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
- Imagine and Merrimac (Stanford) are stream processors: kernels read operands from local registers, streams
  between kernels stay in a software-managed stream register file, and a host issues coarse stream instructions
  (load a stream, run a kernel) instead of single operations.
- Sequoia (Stanford) is a programming model for explicit memory hierarchies: a machine is a tree of memories, a
  program a hierarchy of tasks whose block sizes are set per machine in a separate mapping file.

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
3. **Memory.** The core has 32 KiB of program and data memory on the FPGA (8 KiB in the Basys3 build) and no DRAM
   path, so only small tiles fit.
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
   capacity question for 2:4. On the ZedBoard the delay can be checked against the real DDR3 (PS, HP ports).

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

## Ideas taken from UT Austin work (SST, ELSA, ATB, HMix, CoMeFa, MAFAT, GEMM on AI-optimized FPGAs)

Reviewed on 2026-11-21 from the full papers (SST, ELSA, MAFAT, ATB, HMix, CoMeFa, the FCCM 2024 GEMM paper) and
from the ECE382M.20 SoC Design lectures (Gerstlauer, Lecture 10 "System Integration & Accelerator Interfacing";
McDermott, "HW Accelerators and Co-Processors", both Fall 2026). Some SST overhead numbers came from a summary of the
paper's later sections and are not checked word for word.

1. **A 2:4 processing element that skips zeros (from Systolic Sparse Tensor Slices, Taka et al., FPGA 2025).** The
   weights are the sparse operand: each group of four keeps its two non-zeros and a 2-bit index per non-zero (1.6x
   smaller than dense INT8). The dense activations reach each PE through a 4:1 multiplexer driven by the index, and
   the four activations stay in registers for two cycles, so a PE does one MAC per cycle and the array runs 2:4 at
   twice the dense rate. The slice is a 4 x 4 output-stationary array (INT8 multiply, INT32 accumulate), and a 2-bit
   `sparsity_level` input switches between dense, 2:4, 1:3 and 1:4 at run time. Here, the hand-written coprocessor
   copies this PE and the run-time switch, because the dental model's output head (`head.1`) must stay dense. SST's
   only CNN result (ConvNeXt-S) comes from an analytical model, so a measured CNN segmentation model on a board is
   new data rather than a repeat.
2. **A sparse dot-product instruction (idea from item 1, open question).** Six of the seven inner-loop instructions
   are address arithmetic and loads, so the question is whether 2:4 can cut data movement inside the core. One 2:4
   group (two s8 non-zeros and two 2-bit indices) takes 20 bits, so a 32-bit register holds only one group: an
   `sdot4 rd, rs1, rs2` with four u8 activations in `rs1` and one group in `rs2` stores weights 1.6x smaller but
   needs as many weight loads and instructions as `dot4`. Saving instructions needs two groups per instruction, for
   example four non-zero weights in one register and their indices in a third source register (R4-type) or a
   per-tile index register. The golden model measures both forms on `head.0.block.3` with the dental 2:4 mask,
   including the cost of unpacking indices, and compares them with `dot4` in instruction count; the RTL joins the
   shared INT8 / INT4 dot unit (item 1 of the Duet / MFSA section) only if the count drops.

   Measured on 2026-11-21 (golden model, branch `sparse-dot`, `make sparse-iss BLOCK_WEIGHTS=<layer.json>`): the
   real 2:4 weights of `head.0.block.3` from the dental model with 45 layers at 2:4 (seed 0, fold 0, first 8 of 32
   output channels, all 576 groups with exactly two non-zeros); random 2:4 weights give the same counts. All
   builds match the expected output. `sdot4` is `custom-0` funct3 3; `sidx` (funct3 4) loads an index register;
   `sdot8` is R4-type on `custom-1` and shifts the index register by 8 bits after each use (`sw/c/sdot.h`).

   | Build | Convolution | Whole block | Weight bytes |
   | --- | ---: | ---: | ---: |
   | `block_nn` (dense `dot4`) | 76,261 | 78,504 | 2,304 |
   | `block_sa` (`sdot4`, one group per instruction) | 76,261 | 78,504 | 2,304 |
   | `block_sb` (`sidx` + `sdot8`, two groups per instruction) | 55,426 | 57,671 | 1,440 |
   | `block_rb` (dense `dot4`, 2 x 4 register block, no new hardware) | 31,080 | 33,325 | 2,304 |

   `sdot4` changes nothing, as predicted. The `sdot8` inner loop is 8 instructions for 8 input channels (three
   loads, `sdot8`, the add, two address increments, the branch) against 14 for two `dot4` iterations, but the
   convolution drops only 1.38x: with CIN 32 each 3 x 3 position runs four `sdot8` and one `sidx`, and the outer
   loops stay. Register blocking without any new hardware is still 1.78x fewer instructions than `sdot8`. The two
   do not combine freely: one index register serves one output channel at a time, so a register-blocked `sdot8`
   can reuse weights across pixels but not across output channels (each channel has its own indices). So 2:4 in
   the core buys 1.6x smaller weights and at most 1.38x fewer instructions, at the cost of a third register read
   port and index state the core must save; the measured case for skipping zeros stays with the coprocessor
   (item 1).
3. **One N:M level per layer (from ELSA, Huang et al., CVPRW 2024).** ELSA picks each layer's sparsity from the set
   the accelerator supports ({1:4, 2:4, 4:4}); DeiT-B goes from 17.6 to 6.0 GFLOPs at 81.8% to 81.4% accuracy, against
   9.2 GFLOPs at 81.6% for uniform 2:4. Here, the coprocessor supports the same three levels, and the dental project
   measures each layer's sensitivity to 1:4 on the CV folds (planned in `~/YOLOv8/EXPERIMENTS.md`, to-do list). It
   is an input to the design space, not a deployment change.
   Done on 2026-11-21 (`nm_sensitivity.py`, seed 0, CV only, no fine-tuning): 15 of 45 layers alone lose at most
   0.5 points of hit rate and 0.005 mf Dice at 1:4, but they are small encoder layers (18.6% of the dense MACs),
   while the largest decoder and head layers lose 0.02 to 0.045 mf Dice; switching the 15 together loses 8.6
   points of hit rate (CI -11.1 to -5.9) for 9.2% fewer effective MACs. Per-layer sensitivities do not add up.
   With fine-tuning the picture changes (`nm_followup.py`, same budget as the 2:4 model: 15 epochs, lr 3e-5,
   criteria set before the run): all 45 layers at 1:4 recover to -0.18 points of hit rate (CI -1.61 to +1.43) and
   -0.010 mf Dice for 48.5% fewer effective MACs, passing; the 15 tolerant layers alone end at -1.07 points (CI
   -2.33 to +0.18), just failing, which looks like single-seed noise. So a no-fine-tuning scan does not predict the
   fine-tuned result, and 1:4 has seed-0 FP32 support: the coprocessor keeps the dense, 2:4 and 1:4 modes of item 1
   (1:4 halves the effective MACs again on the same processing elements). 1:4 with INT8 QAT, over five seeds
   (2026-11-21, `run_nm14_int8.sh`, criterion set before the run), matches dense INT8 on the CV folds: -0.04 points
   of hit rate (CI -0.88 to +0.81) and -0.005 mf Dice (CI -0.011 to +0.001); against 2:4 with INT8 it is -0.54
   points (CI -1.25 to +0.18). In the analytical accelerator model (`accel_lowbit.py`, R34/512 five folds, 1 MB
   SRAM, 12.8 GB/s) a 64 x 64 array takes 140 / 80 / 59 ms for dense / 2:4 / 1:4 at 1.00 / 0.62 / 0.44 of the INT8
   energy; at 4 GB/s it is memory-bound (217 / 188 / 171 ms), so on a board with slow DRAM 1:4 buys little time
   over 2:4. 2:4 stays the main candidate (its integer and fixed-point paths are already checked); 1:4 is a
   run-time mode of the same array.
4. **Tiles sized by a memory predictor (from MAFAT, Farley and Gerstlauer, IESS 2022).** MAFAT predicts a tile's
   memory as scratch + output + 2 x input and searches fusing cuts and tile counts until the prediction fits the
   limit; on a Raspberry Pi 3 with 16 MB it is 2.78x faster than the untiled run and within 6% of the best measured
   setting. Here, the same predictor picks the tiles for the one-layer board run in December (Nexys A7, 32 KiB data
   memory, a 512 x 512 layer), so tile sizes are computed before the run rather than found by trial on the board.
   Done on 2026-11-21 (branch `tile-plan`, `sw/tile_plan.py`): the predictor is the memory `block.c` allocates for
   one tile plus a fixed part (code, stack) measured from six builds of `block_rb` (at most 1,056 B); predictions
   matched the linked programs within 20 B (8 x 16 x 16: 22,844 B exactly; 16 x 16 x 16 predicted 38,716 B, the
   link overflowed 32 KiB by 5,952 B, i.e. 38,720 B). Golden-model instructions per tile fit 259 per output (fit
   error 0.5%), so on `block_rb` the tile shape changes the data moved, not the compute. For `head.0.block.3`
   (512 x 512, CIN 32, COUT 32) in 32 KiB, the largest tile with all 32 output channels is 8 x 8 x 32 (25,040 B,
   passes); the shape that moves least data for the whole layer is 8 x 16 x 16 (4,096 tiles, 45 MB between host
   and board against 54 MB for 8 x 8 x 32), 2.17 G instructions in all, about 43 s at an assumed 50 MHz. At
   115,200 baud, 45 MB is over an hour of UART traffic, which confirms that the whole layer belongs on the ZedBoard.
   Later, on the ZedBoard, consecutive layers are fused to keep intermediate maps out of DDR3. MAFAT was tested only
   on YOLOv2; the U-Net adds skip connections whose encoder maps must stay alive until the decoder uses them, which
   MAFAT does not model.
5. **INT32 partial sums, one requantization (from HMix, Shyam, Nag and John, CF 2026).** HMix is a 16 x 16
   output-stationary INT8 systolic array on a ZCU106. Its partial sums stay at 32 bits in BRAM until the whole
   reduction is done, the previous layer's output is added into the partial sum (the residual), and only then is the
   result requantized to INT8. This is the dental fixed-point rule decided on 2026-11-11 (bias and residual additions
   keep 8 extra fractional bits, rounded once), so the coprocessor requantizes once, when results drain. Its results
   table (device, precision, frequency, BRAM / DSP / LUT / FF, FPS, FPS/W, FPS/DSP) is the model for this project's
   coprocessor table.
6. **Buffer sizes from an analytical model (from Asymmetric Tile Buffering, DAC 2026, and the FCCM 2024 GEMM
   paper).** ATB models an output-stationary tile's arithmetic intensity as AI = 2 / (a/T_N + b/T_MC + c/K) under the
   buffer limit (2a/rho)·T_MC·T_K + 2b·T_K·T_N + c·T_MC·T_N <= S, with a kernel-switch cost (about 50 cycles), and
   takes performance as min(AI x bandwidth, core efficiency x peak). With INT8 inputs and INT32 outputs (a = b = 1,
   c = 4 bytes), the output buffer dominates, which favours output stationary. The FCCM 2024 paper (Taka, Gourounas,
   Gerstlauer, Marculescu, Arora) found that Vitis HLS's automatic buffer mapping used 133% of the URAM and failed
   place and route, and fixed it with an analytical model of tile sizes and BRAM / URAM mapping that matched exactly.
   Here, the per-layer cost model takes ATB's form, and the coprocessor's tile sizes and BRAM mapping are computed
   from it before the RTL is written. The coprocessor's dataflow (weight or output stationary) is chosen with this
   model instead of being fixed in advance.
7. **Energy split into compute and data movement (from CoMeFa, Arora et al., FCCM 2022).** CoMeFa adds bit-serial
   processing elements inside BRAMs; its energy model credits the savings to data movement that no longer happens.
   Here, the PrimePower split in item 3 of the Duet / DICE section adds bytes moved per layer, so energy can be
   divided into arithmetic and data movement. CoMeFa itself needs a modified FPGA BRAM, so it is not built; at most
   it is a modelled point in the coupling comparison.
8. **Coupling levels and the offload test (from ECE382M.20 Lecture 10 and the accelerators lecture).** The course
   lists four couplings: a bus-slave accelerator the CPU copies data into; a bus slave fed by a DMA controller; a
   bus-mastering accelerator with its own DMA; and a cache-coherent accelerator (Zynq ACP). Offloading pays when
   n(t_CPU - (t_in + t_exec + t_out)) > 0. ACP suits medium-grain tasks, not instruction-level ones. Polling has the
   lowest latency; interrupts suit coarse tasks, and measured Linux interrupt latency on a Cortex-A9 reached 43 ms
   under heavy load. Here, coupling point 2 starts as a bus slave with AXI-Lite control registers (start / done,
   polled) and becomes bus mastering (AXI HP to DDR3) for whole layers; the host program runs bare metal with
   polling, so the measured t_in and t_out (the Duet-style microbenchmark) are not mixed with OS noise. The course's
   hardware abstraction layer, where the same C function call runs the software kernel or the accelerator, is the
   shape of the shared host program planned for 2/20, and double buffering overlaps transfers with compute.

Not taken: Versal AI Engines and Stratix 10 NX tensor blocks (FCCM 2024), the supernet and evolutionary search
(ELSA; a per-layer sensitivity scan is enough for one model), modified BRAMs (CoMeFa), the 1:3 level (SST), and
Linux kernel drivers and device trees (Lecture 10; bare metal first).

## Ideas taken from Merrimac and Imagine

Reviewed on 2026-11-22 from the full SC'03 paper (Dally et al., "Merrimac: Supercomputing with Streams") and from
Khailany's Stanford thesis on Imagine (2003), whose stream instruction set Merrimac follows. Merrimac is a 90 nm
design evaluated on a cycle-accurate simulator, not a built chip. Facts used below, all checked in those two sources:

- Merrimac node: 16 clusters of four 64-bit multiply-add units at 1 GHz (128 GFLOPS); 768 words of local registers
  (LRF) per cluster; an 8K-word stream register file (SRF) bank per cluster, 128K words (1 MB) in all; an 8-bank
  512 KB cache; 20 GB/s of DRAM bandwidth, a FLOP / word ratio over 50:1. Each cluster reaches only its own SRF bank,
  over short wires and without tags; a global switch joins the clusters and the cache banks.
- In the three applications, over 96% of all references come from the LRFs and under 1.5% from memory (Table 2 of
  the paper lists LRF, SRF and memory references per application). The SRF's bandwidth is about an order of
  magnitude below the LRFs'.
- Data moves a strip at a time. The compiler sizes a strip to fill the SRF without spilling, and strips are software
  pipelined: strip i+1 loads while the kernels run on strip i and strip i-1 is stored.
- Merging kernels passes intermediate results through the LRFs instead of the SRF, at the cost of LRF capacity.
- Memory and compute were balanced by cost: the last dollar spent on each should buy the same gain, not a fixed
  FLOP / byte ratio.
- Imagine: the host writes stream instructions into a 32-entry operation buffer, each with a bitmask of its
  dependencies on the other entries. A scoreboard issues an instruction once its dependencies are done and its unit
  is free, so the host can run up to 32 instructions ahead. Kernels are scheduled into VLIW code at compile time;
  only stream instructions are scheduled at run time. The address generators support sequential, strided, indexed
  and bit-reversed access, and the memory controllers reorder accesses to keep the DRAM busy.

1. **References per level in the cost model.** The per-layer cost model reports Merrimac's Table 2 for each layer
   and each coupling point: words read or written in the PE registers / accumulators, in the scratchpad and in DDR3,
   with the share of each. The roofline then gets two bandwidth lines (scratchpad and DDR3) instead of one. The event
   counters (5/8) count scratchpad and DDR3 words, so the board run gives the same table as the model.
   First numbers, for coupling point 1 on the golden model (`make block-refs`, `sw/iss.py --refs`, 2026-11-22):
   for the 8 x 16 x 16 tile of `head.0.block.3` that `sw/tile_plan.py` picks for the Nexys A7 (589,824 MACs),
   `block_nn` makes 2.82 M register-file references and 0.31 M data-memory references (9.9%) and loads
   1.21 MB, 2.05 B per MAC; `block_rb` makes 1.35 M and 0.13 M (8.8%) and loads 0.48 MB, 0.81 B per MAC. The
   tile itself is 21.8 KB, so even register blocking reads each tile byte from memory about 22 times; this is the
   traffic a coprocessor with its own buffers removes. Merrimac's applications kept 93.6 to 97.5% of references
   in the LRFs; the core keeps about 90% in the register file, but its memory references are words loaded one
   per instruction, not streams. Counts depend only on the shape, not on the weight values.
   Split per phase (`make block-refs` with `--profile`, the deployed layer's weights, 4 x 4 x 8 tile): in `block_nn`
   the convolution makes 96.6% of the data-memory references (18,712 of 19,374) and requant, pooling and start-up the
   rest, so a coprocessor that takes the convolution and requant (Gemmini item 1) removes almost all of the memory
   traffic the core sees.
2. **A command queue with dependency bits (from Imagine's stream controller).** Instead of single start / done
   registers, the coprocessor takes commands `{op, base, stride, count, buffer}` through a small FIFO (for example 4
   entries), each with a bitmask of the earlier entries it waits for. Two units, DMA and compute, issue from it, so
   the load of the next tile can start while the current one computes and the host does not wait for each step.
   This adds one number to the coupling comparison: MACs per command, the control cost the core pays at each point.
   It fits after the plain start / done version from 2/20 works.
3. **Tiles sized for three buffers.** The tiling function (Gemmini item 3, the MAFAT predictor in the UT Austin
   section) picks, at compile time, the largest tile for which load, compute and store buffers all fit in the
   scratchpad, so double buffering (Gemmini item 6) needs no spill.
4. **Skip connections as long-range producer-consumer traffic.** Merrimac keeps short-range reuse in the LRFs and
   long-range reuse in the SRF. In the U-Net, a skip feature map is produced by the encoder and used much later by
   the decoder. The cost model lists skip traffic as its own row and decides per level whether it stays in the
   scratchpad or goes through DDR3. The same applies to fusing the residual add into the convolution: the residual
   tile must stay in the buffer, the capacity cost Merrimac notes for merged kernels.
   Computed on 2026-11-22 for the dental U-Net (`skip_traffic.py` in the dental repository, shapes only, INT8,
   the same tiling model as its `accel_explore.py`): the four skips are 0.26, 0.52, 1.05 and 4.19 MB (6.03 MB, the
   largest, `stem`, alive across 41 layers), plus 16 ResNet residual identities of up to 1.05 MB. For the deployed
   slim-decoder model (24.13 G MACs, 22.57 MB of INT8 weights) one 512 x 512 ROI moves 135.6 MB with 512 KB of
   SRAM, 112.0 MB with 1 MB, 57.5 MB with 4 MB and 44.8 MB with 8 MB. Up to 1 MB no skip can stay on chip, and
   skips and residuals are 21% of the traffic at 512 KB; keeping everything on chip needs 8.91 MB. The earlier
   all-or-nothing skip rule missed the residual traffic (8.4 MB at 1 MB, an upper bound).
   The deployed model has no `head.0.block.3` (its output head is a 1 x 1 convolution at half resolution); the same
   32-to-32 3 x 3 block is its `decoders.3.block.3` at 256 x 256 (same weight shape, 0.60 G MACs), so whole-layer
   numbers for the deployed model use 256 x 256: on the Nexys A7, 1,024 tiles of 8 x 16 x 16 and 11.3 MB moved
   (45.1 MB for the 512 x 512 layer of the main model).
5. **One bank per lane, no global crossbar.** Each lane of the INT8 array reads only its own scratchpad bank (for
   example a BaseJump 1R1W memory), and the 2:4 selection stays a 4-to-2 mux inside the lane (SST, UT Austin item
   1), so the wiring does not grow with the array.
6. **Address modes of the DMA.** Sequential and 2-D strided access cover tiles and im2col without the core
   rearranging data. Indexed access is not needed for 2:4, because the 2-bit indices are stored with the weights.
7. **Balance by marginal gain.** In the design-space sweep, array size, scratchpad size and DDR3 bandwidth are chosen
   by the gain in the final metric per added LUT / BRAM / DSP, not by a fixed MACs-per-byte ratio.

Not taken: 64-bit floating point, the multi-node network (high-radix routers, Clos), scatter-add (CNN inference does
not need it), the cache next to the SRF, VLIW kernel microcode and the stream compiler, and DRAM access reordering
(it makes memory latency depend on the access mix; this project keeps a simple in-order DMA so that board and
simulation cycle counts can match).

## Ideas taken from HPS

Reviewed on 2026-11-22 from the full papers (Patt, Hwu and Shebanow, "HPS, A New Microarchitecture: Rationale and
Introduction", and Patt, Melvin, Hwu and Shebanow, "Critical Issues Regarding HPS", both MICRO 1985) and the 2014
IEEE Micro retrospective. HPS (High Performance Substrate) is a restricted-dataflow out-of-order microarchitecture:
each instruction is decoded into a small dataflow graph of micro-operations, and a Merger joins it to the graph of
an active window of the instruction stream. The Merger uses a Register Alias Table (a ready bit and a result tag per
register, a modified Tomasulo algorithm) to resolve dependencies. Nodes wait in small content-addressable node tables
until their operands arrive, and instructions retire in order, so exceptions stay precise. The retrospective credits
it as the approach used from the Pentium Pro on. The whole engine is not taken: the core is single-cycle, and
renaming, node tables and repair do not serve this project's accelerator question. Three ideas are taken:

1. **The three tiers as the frame of the coupling comparison.** HPS argues for large-grain dataflow at the top,
   sequential control flow in the middle (the ISA) and fine-grain dataflow at the bottom. The three coupling points
   sit on the same scale: the hls4ml `io_stream` design is dataflow, the core with `dot4` is sequential control flow,
   and the coprocessor with a command queue (Merrimac and Imagine, item 2) is coarse-grain dataflow driven by a
   sequential host. The comparison measures where control flow should hand over to dataflow for this workload.
2. **Non-blocking long-latency instructions (later).** If `dot4` or a coprocessor command takes several cycles, the
   simplest core stalls until it is done. A busy bit per destination register, set when the instruction issues and
   cleared when its result arrives, lets later instructions that do not read that register keep issuing. This is the
   ready-bit half of the HPS Register Alias Table, without renaming; the HPS paper notes that such schemes still stall
   on a true dependency, which is acceptable here. Blocking and non-blocking versions of the same instruction become
   one more point in the coupling comparison, next to the RoCC-style variant (Chipyard item 2). Only worth doing once
   the valid / ready `dot4` is multi-cycle.
3. **Checking at the retire point.** HPS keeps out-of-order execution correct by committing state in order at
   retirement. The golden-model comparison already uses the `retire_*` ports; they stay the single comparison point
   if the core is later pipelined, gets non-blocking instructions or the board retire signature (FireSim item 1), so
   the checker does not change with the microarchitecture.

Not taken: register renaming, node tables and tag broadcast (the coprocessor's queue uses Imagine-style dependency
bitmasks), the node cache, branch prediction and repair, the Memory Alias Table and write buffer, and an
out-of-order core in general.

## Ideas taken from Sequoia

Reviewed on 2026-11-22 from the full paper (Fatahalian et al., "Sequoia: Programming the Memory Hierarchy", SC'06,
Stanford; Dally and Erez among the authors). Sequoia models a machine as a tree of memory modules (Cell: main memory
and eight 256 KB local stores) and a program as a hierarchy of tasks: side-effect-free functions with
call-by-value-result arguments whose whole working set must fit in one memory module. `inner` variants only split
their arguments into blocks and call subtasks; `leaf` variants compute, usually wrapping a platform kernel in C.
Block sizes are `tunable` parameters left unbound in the source; a separate mapping specification per machine picks,
for each level, the variant, the tunable values and options such as double buffering (`software-pipeline`) and
copying blocks into contiguous buffers. `rchop(A, offset, len, stride)` cuts possibly overlapping blocks. Its
benchmarks include `ITERCONV2D` (a 9 x 9 convolution), results are split into leaf compute, waiting on memory and
overhead, and the paper says the model suits regular programs only, which the U-Net is. The language and its
compiler are not taken; the program structure is.

1. **A memory tree and a mapping file per board.** Nexys A7 (32 KiB, no DRAM), Basys3 (8 KiB) and the ZedBoard (DDR3,
   BRAM scratchpad, PE registers) are each described once, and the tiling function (`sw/tile_plan.py`) writes a
   mapping per board and layer: tile sizes, the leaf variant and the options below. The code does not change between
   boards; this can share a generator with the register table (2/20). Done for the core on 2026-11-22:
   `sw/tile_plan.py --board nexys_a7|basys3 --mapping FILE` writes the board's memory tree, the layer, the leaf
   (`block_rb`), the tile with the least data moved and the options (double buffering and contiguous copies, both
   off until there is a DMA), and `make ... MAPPING=FILE` builds that tile. For `head.0.block.3` at 512 x 512 it
   picks 8 x 16 x 16 on the Nexys A7 (predicted 530,288 instructions per tile, measured 528,851) and 4 x 8 x 8 on the
   Basys3 (142.6 MB moved, against 45.1 MB). The ZedBoard entry waits for its bring-up.
2. **The coupling points as leaf variants of one task.** One tiling (`inner`) drives every leaf: `block_ref`,
   `block_dot4`, `block_rb`, the coprocessor and the hls4ml design. Each coupling point then differs by one line of
   the mapping, so all of them tile the layer the same way and the difference comes only from the leaf (the same aim
   as the hardware abstraction layer in the UT Austin section, item 8).
3. **Call-by-value-result as the coprocessor's command semantics.** A command is a task call: its input blocks are
   copied into the scratchpad, its output blocks are copied back when it is done, the host does not touch that
   scratchpad region while it runs, and output blocks of commands in flight do not overlap. No coherence is needed,
   and this fixes the boundary for a later shared-SRAM partition (CacheFlex, item 4) and the meaning of the command
   queue (Merrimac and Imagine, item 2).
4. **Halo tiles as `rchop` blocks.** The DMA descriptor carries offset, length and stride per dimension, which
   describes the overlapping input tiles of a 3 x 3 convolution (with the 2-D strided mode in Merrimac item 6).
5. **Double buffering and contiguous copies as mapping options.** Both are switched in the mapping, not in the code,
   and measured on and off.
6. **Time split three ways.** The event counters (5/8) report leaf compute, waiting on memory and overhead (command
   issue, synchronization) for each coupling point, as in Figure 11 of the paper; the Duet-style microbenchmark
   measures the overhead part.
7. **The tunables as the search space.** The design-space sweep uses the mapping's parameters (tile sizes, array
   size, scratchpad size, reuse factor) as its variables.

Not taken: the Sequoia language and compiler, virtual levels and clusters, MPI, parallel `mappar` over many
processing units (there is one coprocessor), `gather` / `ichop` (2:4 indices are stored with the weights).

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

- Before the one-layer board run (12/9 to 12/16): a script that picks the tile sizes for the 32 KiB data memory
  with MAFAT's memory predictor (item 4 of the UT Austin section), so the board run does not search by trial.
- Golden model of the sparse dot-product instruction in both forms (item 2 of the UT Austin section), compared with
  `dot4` on `head.0.block.3` with the dental 2:4 mask. It needs no RTL and can be done at any time.
- Cycle counts, LUT / FF / DSP and Fmax on the FPGA (Nexys A7; Basys3 as a build-only column) with and without
  each instruction.
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
  through the ASIC flow, for energy per MAC (PrimePower). The hand-written
  coprocessor (decided 2026-11-21, after May, on the ZedBoard) is a small INT8 array (for example
  8 x 8; weight or output stationary, chosen with the buffer model in item 6 of the UT Austin section) whose
  processing elements follow SST (item 1 there): it stores 2:4 weights with their 2-bit indices in its own buffer,
  skips the zeros, switches to dense for the output head, requantizes once as results drain (HMix, item 5), and
  reads whole layers from DDR3: it compares hand-written RTL with HLS, and it is the first design here where 2:4 can pay off, joining
  the dental project's INT8 + 2:4 accelerator candidate. A
  per-layer cost model calibrated on these points extends them to latency and energy per panoramic X-ray and to a
  small design-space sweep under one final metric (see "Ideas taken from ReaLLM and Chiplet Cloud"). Planned
  for after May 2027; the UART bridge and control registers from the board test can be reused.
- Gemmini in simulation (Chipyard, Verilator) as a reference point for the loosely-coupled end, run on the same
  convolution layer for cycle counts. Optional and only if a paper or the SOP needs it: the install is large (many GB
  and a conda environment, with 10 GB of memory in WSL), and it is not this project's own design.
