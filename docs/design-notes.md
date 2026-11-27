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
   Skeleton written on 2026-11-22 (draft contents, decided on 2/20): `sw/regs/regs.json` -> `sw/regs/regtool.py` ->
   `build/regs/soc_regs.{sv,h,md}` (`make regs-test`: Verilator lint clean, and `tb/tb_soc_regs.sv` checks read-back,
   read-only inputs, the start / clear pulses and an unused offset). The four existing I/O registers are marked
   external (still decoded in `fpga/rtl/soc.v`) and only go into the header and the map; the draft block holds CTRL,
   STATUS, the gated cycle counter, four event counters, the retire signature and a scratch register.
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
   run-time mode of the same array. Updated on 2026-11-22 for the deployed configuration (`accel_deploy.py
   --tiling v2`: slim decoder, INT8 cascade with 2.58 models per ROI on average, skips and residuals tracked per
   layer, the corrected tiling below): 45 / 27 / 19 ms at 12.8 GB/s and 68 / 60 / 53 ms at 4 GB/s, and INT8 + 2:4
   uses 0.19 of the main model's INT8 energy. The model was then cross-checked against Timeloop and Sparseloop on
   four layers (criteria set before each run): the first tiling never underestimated DRAM traffic but overestimated
   a layer whose 885 KB of weights nearly fill the 1 MB SRAM by 82% (it tried only power-of-two tiles and reloaded
   both inputs and weights); the corrected tiling is within 0.93-0.99 of Timeloop's minimum on all four layers, also
   with the array held at full speed. For 2:4, weight traffic agrees within 3% and the cycle ratio (0.50) matches
   on two of three layers; on the third the model rounds 4.5 array passes up to 5, which the hardware has to do.
   Energy constants are not checked externally.
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

## Ideas taken from ASU work (SAFER, PIM vs FPGA, HISIM, CoMeFa, FPGA-for-DL survey)

Reviewed on 2026-11-27. Read in full: SAFER (Sridharan, ..., Jeff Zhang, Seo, Fan, ESSERC 2025; NSF PAR author
copy, figures and tables not extracted), the PIM-vs-FPGA study (Kochar, Ekiert, Najafi, Fan, Angizi, GLSVLSI 2023;
NSF PAR) and SST (arXiv 2502.03763). Read in part: CoMeFa (architecture and results), HISIM (Wang, ..., Jeff Zhang,
Chakrabarti, Ogras, Cao, IEEE TCAD 2025; NSF PAR author copy, validation and design-space sections) and the
FPGA-for-DL survey (Boutros, Arora, Betz, arXiv 2404.10076 v1, passages on sparsity, bandwidth and inference styles
only). Items already taken from SST and CoMeFa are in the UT Austin section and are not repeated.

1. **The core moves data, the array does the MACs (from SAFER).** SAFER is four in-SRAM sparse MAC cores (28 nm,
   0.95 mm^2) next to a custom 32-bit single-cycle RV32IM core. The core does no MACs: extra load / store
   instructions compute addresses and unicast or multicast weights, inputs and outputs between the input buffers
   (0.5 KB per core), the two 1 KB output buffers and the CIM arrays; global status registers report each core's
   state; FP8 and INT32 vector additions in the core sum the partial results of matrices larger than one array. Each
   compute column also has a backup SRAM (64 weights) so the next weights load while the current ones compute.
   Here, this is the division of work for coupling point 2: six of the seven `dot4` inner-loop instructions are
   address arithmetic and loads, so the core's new instructions should move data into the coprocessor's buffers
   (one word, or one word to several PE rows) and add INT32 partial sums when the reduction is split across tiles,
   with status polled from a register, while the array does the MACs. It is measured against `dot4` and
   `block_rb` on the same block, in instructions issued by the core and in cycles. The backup weight buffer is the
   double buffering already planned (item 8 of the UT Austin section).
2. **Sparsity for capacity, measured on silicon (from SAFER).** SAFER stores only the non-zero weights and one
   index each (index width set by the largest M supported) and streams all M inputs for every row regardless of N,
   so the cycle count is normalized to M: N:M saves storage, not time. With 1:16, ResNet-18 (CIFAR-100, about 11 M
   parameters) needs 91 macros, 15.5x fewer, and the paper's figure of merit is TOPS/W/mm^2 x weights per byte.
   Here, this is measured support for item 3 of the ReaLLM / Chiplet Cloud section. The coupling table gets a
   weight-footprint column with the indices counted (INT8 2:4 is 0.625 of dense, 1:4 is 0.3125), and the final
   metric may include it, since on the Nexys A7 the weights of a layer compete with activations for BRAM.
3. **Activation bandwidth sets the 2:4 ceiling (from SST, detail not in the UT Austin section).** In 2:4 mode each
   SST processing element loads four activations at once and keeps them for two cycles, so it reads activations at
   twice the dense rate; the sparse modes need four activation banks instead of one, and a sparse weight bank is 40
   bits wide instead of 32 (data plus indices). The paper's measurement of AMD Versal AIE-ML, which supports 2:4 in
   hardware, shows what happens without that bandwidth: utilization falls from over 90% (dense) to 51.6% at 2:4,
   and a 64^3 INT8 GEMM gets only 13% faster (4.5% in bf16), which the authors attribute to vector load / store
   bandwidth. Here: (a) check that the dental analytical model (`accel_deploy.py`) and the Sparseloop
   architecture used in the cross-check charge 2:4 for the doubled on-chip activation reads, not only the DRAM
   traffic; (b) the coprocessor's activation buffer is banked for M/N times the dense read rate; (c) the AIE-ML
   result is outside evidence that the missing CPU speedup is a bandwidth effect, and the README can cite it.

   Done on 2026-11-27 for (a) (dental `accel_onchip_bw.py`, commit `b897bdb`, prediction written first): the
   model charged the 4/N activation reads in energy only, and per-tile cycles assumed the global buffer delivers
   them at any rate; the Sparseloop GlobalBuffer had no bandwidth either, so the matching 2:4 cycle ratio (0.500)
   did not test it. With a read limit of B bytes per cycle (as a multiple of the dense need), the deployed model
   (64 x 64, 1 MB, 12.8 GB/s, per ROI) gives: dense INT8 45.3 ms at every B; INT8 2:4 42.1 / 26.9 / 26.9 / 26.9 ms
   at B = 1x / 2x / 4x / unlimited (1.08x over dense at 1x, 1.68x from 2x on); INT8 1:4 45.9 / 25.8 / 19.2 / 19.2 ms.
   The prediction that 2:4 gains at most 5% at 1x failed narrowly (1.08x; the extra 3% is the array fill saved by
   half as many tiles and the smaller weight traffic). So the coprocessor's activation buffer needs 4/N times the
   dense read width (two banks for 2:4, four for 1:4), as SST builds it; at 4 GB/s DRAM still dominates.
4. **Calibrate on one layer, report the error on others (from HISIM).** HISIM calibrates one constant (the
   latency of the crossbars mapped to VGG16's first layer) to measured data and then predicts the first seven
   layers of VGG16 and MobileNet within 5.3%; its systolic-array model is calibrated with Scale-Sim and 28 nm
   synthesis, its network model with BookSim, with a plot of model error against evaluation speed; it evaluates
   672 configurations in 48.8 s, 10^4 to 10^6 times faster than the simulators it replaces. Its authors plan a CPU
   model calibrated on RISC-V silicon. Here, the one-layer board run calibrates the per-layer cost model on
   `decoders.3.block.3` and checks it on a second layer of a different shape that is measured but not used for
   fitting, reporting that held-out error; the Timeloop cross-check table gets a column for model run time.

   Chosen on 2026-11-27: the held-out layer is `decoders.3.block.0` (96 -> 32 channels, 256 x 256, 1.81 G MACs, the
   deployed U-Net's largest layer): same output size as `decoders.3.block.3`, three times the reduction length, so it
   tests how the model scales with CIN. On the Nexys A7 (32 KiB) the tile that moves least data is 8 x 8 x 16 (2,048
   tiles, 48.8 MB, 1.56 G golden-model instructions); with all 32 output channels only 2 x 2 x 32 fits. A golden-model
   preview of the check (criterion set first: within 10% on every shape): the instruction fit calibrated at CIN 32
   (`build/tile_plan_cal.json`), scaled by CIN, predicts the six CIN 96 calibration shapes 4.4% to 5.8% high, so it
   passes, but the bias is systematic: part of the cost per output does not grow with CIN (loop overhead per 3 x 3
   position). Fitted on both, instructions per output = 15.2 + 7.62 x CIN, and the board model takes that form. The
   CIN 96 fit is kept in `build/tile_plan_cal_cin96.json`; `build/tile_plan_cal.json` stays at CIN 32 for the
   December run. Its fold-0 weights were exported the same day (`sw/export_layer.py --conv decoders.3.block.0 --bn
   decoders.3.block.1`, `build/unet/slim_d3b0_fold0_c{8,16,32}.json`, not in git; re-exporting `decoders.3.block.3`
   gave a file identical to the existing one, so it is the same checkpoint). On the 8 x 8 x 16 tile with these
   weights `block_mul`, `block_dot4`, `block_nn` and `block_rb` pass on the golden model; `block_rb` runs 760,797
   instructions, against 762,137 predicted by the CIN 96 fit (+0.2%) and +4.6% by the CIN 32 fit scaled by CIN.
   `block_ref` did not finish within 80 M instructions (it spends them in `__mulsi3`) and was not run further.
5. **One measurement boundary for every point (from the PIM-vs-FPGA study, as a warning).** The study compares a
   65 nm 16 kb processing-in-SRAM macro (power estimated for the macro), a PYNQ-Z2 running FINN (XC7Z020, the
   ZedBoard's device; power from a USB meter on the whole board, unused parts included) and an RTX A2000 (power
   halved, then scaled by weight x input bits), and reports 64-160x speedup and up to 228x img/s/W for PIM over the
   FPGA. The three are measured inside different boundaries, so the ratios mix architecture with accounting. Here,
   the coupling points use one boundary: the same layer and INT8 weights, cycles from the same counters, power from
   the same source (Vivado power report or one on-board measurement, stated as core-only or whole-board), and any
   estimated number is marked. FINN's numbers on the XC7Z020 are context only (1- and 2-bit networks, CIFAR-10).
6. **Split the MACs between unit types (from CoMeFa).** CoMeFa partitions GEMV and FIR between DSPs and in-BRAM
   compute: speedup rises with the share given to the BRAMs up to a point, after which loading, unloading and
   bit-serial latency dominate, and the best split differs per application. The DRAM-bound benchmark gains nothing.
   Bit-serial multiplication takes n^2 + 3n - 2 cycles (86 for INT8), so the peak MAC gain falls from 2x at INT4 to
   1.7x at INT8. Here, hls4ml at reuse factor 32 uses all 240 DSPs of the Nexys A7, so the hand-written array maps
   part of its multipliers to LUTs and sweeps the DSP / LUT split for LUTs, Fmax and cycles. Bit-serial compute is
   revisited only for INT4 (W4A8 passed in the dental project).
7. **Name the coupling points by inference style (from the survey).** The survey separates spatial, layer-pipelined
   generators (HPIPE, fpgaConvNet, DNNBuilder, FINN), which build one module per layer, from temporal overlays, a PE
   array driven by instructions, which compile a new model in seconds instead of a bitstream in hours. HPIPE skips
   unstructured zero weights with a soft-logic gather network mapped onto the Stratix 10 NX tensor block's vector
   mode (1.9x over DSPs). The survey names data movement from BRAM to compute (routing, congestion, power), not
   BRAM bandwidth itself, as the bottleneck on the fabric. Here, the README's coupling table labels hls4ml
   `io_stream` as spatial and the core plus array as a temporal overlay, which explains why the spatial point
   covers one layer per bitstream and the overlay can run the whole U-Net.

Not taken: in-SRAM and ReRAM compute-in-memory circuits (they need a tape-out), the FP8 fused dot product (the
dental model is INT8), changes to the FPGA's own blocks (SST, CoMeFa; they need VTR, not a board), and HISIM's
2.5D / 3D, network-on-package and thermal models (one chip here).

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
   Computed on 2026-11-22 for the dental U-Net (`skip_traffic.py --tiling v2` in the dental repository, shapes
   only, INT8, the tiling corrected after the Timeloop cross-check, UT Austin section item 3): the four skips are 0.26, 0.52, 1.05
   and 4.19 MB (6.03 MB, the largest, `stem`, alive across 41 layers), plus 16 ResNet residual identities of up to
   1.05 MB. For the deployed slim-decoder model (24.13 G MACs, 22.57 MB of INT8 weights) one 512 x 512 ROI moves
   109.4 MB with 512 KB of SRAM, 100.8 MB with 1 MB, 56.7 MB with 4 MB and 44.1 MB with 8 MB (the first tiling gave
   135.6 / 112.0 / 57.5 / 44.8 MB, overestimating the layers' own traffic at small SRAM). Up to 512 KB no skip can
   stay on chip (from 1 MB the 0.26 MB `layers.2` skip does), and skips and residuals are 25% of the traffic at
   512 KB; keeping everything on chip needs 8.91 MB. The earlier all-or-nothing skip rule missed the residual
   traffic (8.4 MB at 1 MB, an upper bound).
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

## Ideas taken from PULP and CVA6

Reviewed on 2026-11-22 and checked the same day against the sources: XpulpNN (Garofalo et al., IEEE TETC 2021,
arXiv 2011.14325, full text through the ar5iv HTML; the DATE 2020 version could not be fetched), PULP-NN (Garofalo et
al., Phil. Trans. R. Soc. A 2020, arXiv 1908.11263), DORY (Burrello et al., IEEE TC, arXiv 2008.07127, read through
its results; the last quarter only as a summary), Flex-V (Nadalini et al., arXiv 2307.01056), the CV32E40P user
manual (instruction set extensions), hwpe-ctrl (`hwpe_ctrl_regif_example.rdl`, `hwpe_ctrl_package.sv`) and the HWPE
documentation, the NE16, NEureka and pulp-nnx READMEs, the Siracusa paper (arXiv 2312.14750, first half verbatim),
the CORE-V-XIF specification (latest build of the documentation), and CVA6's README, `config_pkg.sv`,
`ariane_pkg.sv`, `perf_counters.sv`, `core/cvxif_example`, `verif/README.md`, `verif/sim/cva6.py` and
`verif/regress/dv-riscv-arch-test.sh`. Points the sources did not settle are marked as unchecked.

PULP (ETH Zurich and the University of Bologna) is a family of RISC-V cores, clusters and accelerators for low-power
inference. CVA6 (OpenHW Group) is "a 6-stage, single-issue, in-order CPU" implementing RV64 (32-bit configurations
such as cv32a60x, RV32IMC, also exist), and its application-class configurations boot Linux. Neither core is taken:
CVA6 is far larger than a single-cycle RV32I core, and RI5CY / CV32E40P is the kind of core this project writes
itself. Their instruction sets, interfaces and verification methods do apply.

1. **XpulpV2 / XpulpNN as the reference for `dot4`, `dot8` and `requant`.** The packed dot products come in six
   forms: `dotup` / `dotusp` / `dotsp` write `rD = rs1 . op2`, and `sdotup` / `sdotusp` / `sdotsp` add the sum into
   `rD` (the leading `s` means accumulate, not signed). In the suffix the first letter is `rs1` and the second
   `op2`: `usp` is unsigned `rs1` x signed `op2`, the same split as `dot4`. RI5CY wrote them `pv.sdotsp.b`, ...;
   CV32E40P v2 renamed the PULP instructions to `cv.*` (`cv.sdotusp.b`). `cv.clip rD, rs1, I` saturates to
   [-2^(I-1), 2^(I-1) - 1] and `cv.clipu` to [0, 2^(I-1) - 1], so an unsigned 8-bit clip needs I = 9. XpulpNN adds
   nibble (`.n`, eight 4-bit elements) and crumb (`.c`, sixteen 2-bit elements) versions of the dot products and
   of add, sub, avg, max, min, shifts and abs; its requantization is one MAC, one shift and one clip per
   accumulator (`y = m . phi >> d`), the same form as `requant`. Its results come from a post-layout 8-core RI5CY
   cluster in 22 nm FDX: 4- and 2-bit kernels run "6x and 8x faster" than a cluster with only 8-bit SIMD, with a
   peak of 2.22 TOPS/W; on the matrix multiplication alone the gain over 8-bit SIMD is 1.66x (4-bit) and 1.56x
   (2-bit), on a whole convolution layer 1.45x and 1.32x. The layer-level numbers are the fair ones to put next to
   `dot8`, whose 1.71x to 1.76x fewer instructions (golden model, not 2x) have the same cause: address
   arithmetic and requantization do not shrink. They are quoted only with that context (cluster, their compiler
   and kernels).
2. **Hardware loops and post-increment loads as the next candidates, chosen by counting.** XpulpV2's kernels use
   "hardware loops (lp.setup), load with post-increment (p.lw) and the SIMD sdotp". CV32E40P has two loop levels
   (`cv.setup L, rs1, uimm`, `cv.setupi`, and long forms `cv.starti` / `cv.endi` / `cv.count`) and post-increment
   loads `cv.lb rD, (rs1), Imm` (`rD = Mem8(rs1); rs1 += Imm`; if `rD == rs1`, the loaded value wins). Before
   adding either instruction, the U-Net block benchmark counts how many inner-loop instructions are address
   additions, loop counters and branches; that share bounds what the two can save (the post-increment load is
   already in "Next steps").
3. **PULP-NN's register-blocking study as a check on `block_rb`.** PULP-NN tried 1x2, 2x1, 2x2, 4x2, 2x4 and 4x4
   matrix-multiplication kernels and chose 4x2 (four `sdotp4` per two pixels, 5.33 MACs per load; preferred to 2x4
   for its smaller im2col buffer). 4x4 needs "at least 24 registers (16 for the accumulators and 8 for the
   operands)" and makes the compiler spill. Its peak is 15.5 MACs / cycle on eight cores. The same register
   limit was found here (a 4x4 block needs 24 of 31 registers); `make block-refs` already counts loads, so
   the MACs per load of `block_rb` can be put next to PULP-NN's 5.33.
4. **Mac&Load as a point between the two couplings.** XpulpNN's mac&load instructions keep activations and weights
   in a small separate register file (NN-RF; four registers, later two more for activations) and, in the same
   instruction as the dot product, load the next word into one NN-RF register from the address in `rs1`, which is
   post-incremented; the final `nn_sdotp` selects the registers and the update with a 5-bit immediate. The paper
   reports up to 1.64x peak MAC / cycle from this. Flex-V extends it to mixed 8 / 4 / 2-bit formats set by CSRs,
   with a six-register NN-RF and a controller that generates the addresses. This is the "stateful functional unit"
   step already listed as a future extension: a reference for the coupling comparison, not something to build now.
5. **PULP-NN and DORY for layout, tiling and skip buffers.** PULP-NN uses HWC layout because it makes im2col
   cheaper than CHW and splits the work across cores along the output's spatial dimension; sub-byte outputs use
   per-channel thresholds. DORY solves tiling as a constraint program with Google OR-Tools: it maximizes L1
   utilization (input + output + weight tiles), keeps those tiles plus the kernel's own buffers under half of L1
   (room for the second buffer), and adds weighted heuristics that favour tile shapes matching the PULP-NN kernel
   (output channels a multiple of 4, width a multiple of 2, rows balanced over 8 cores). Transfers between L3, L2
   and L1 are asynchronous and double-buffered (the paper also calls the scheme triple buffering). Its objective
   differs from `sw/tile_plan.py`, which picks the tile with the least data moved; both are computed for the board
   layer (`decoders.3.block.3`) and the difference is reported, so the choice of tile is argued, not assumed. DORY
   handles residual connections by giving each L2 output buffer a lifetime counter and running the branch with
   more nodes first; this is the model for keeping U-Net skips in the ZedBoard's buffers (the skip-traffic numbers
   in the Merrimac section). Concatenation, which the U-Net uses, is not mentioned in the parts read.
6. **The HWPE control block for the coprocessor's registers.** In hwpe-ctrl's SystemRDL register description
   (`hwpe_ctrl_regif_example.rdl`) the mandatory registers sit at 0x00 to 0x1C: `commit_trigger` (write 0 to commit
   the job and start it, 1 to commit without starting, 2 to start the queued jobs), `acquire` (a read starts a job
   offload, locks the controller and returns the job ID), `autotrigger` (start the next queued job automatically
   or wait for a trigger), `status`, `running_job` (ID of the running or last job), `soft_clear` (clear the engine
   with or without its registers) and two reserved words. The engine's job-dependent registers start at 0x20 and its
   job-independent ones at 0x40; the job queue is two deep by default (`NB_CONTEXT`). The older
   `hwpe_ctrl_package.sv` numbers its eight mandatory registers differently (`TRIGGER`, `ACQUIRE`, `FINISHED`,
   `STATUS`, `RUNNING`, `SOFTCLEAR`, reserved, `SWEVT`); the `.rdl` is taken as current. The register table
   (`sw/regs/regs.json`, 2/20) starts with the same kind of fixed header (commit / start, acquire, status, running
   job, soft clear) and keeps per-job and fixed parameters in separate blocks; a job queue comes later, with the
   command FIFO of the Merrimac section. The streamers (hwpe-stream) turn "a 3D strided pattern in TCDM" into
   valid / ready streams, the model for the DMA descriptors (Sequoia, item 4).
7. **HWPE-Stream's handshake rules for every valid / ready interface.** Two rules from the HWPE-Stream protocol
   apply to the `dot4` interface (11/26 to 11/27) and the bus outside the core: "the assertion of valid ... cannot
   depend combinationally on the state of ready", and valid may drop only in the cycle after a handshake. They go
   into the testplan as assertions.
8. **NE16 and NEureka as the closest published accelerators.** Both are HWPE-based convolution engines for PULP
   clusters: NE16 supports 1x1, 3x3, depthwise and linear layers with 8- or 16-bit activations and 2- to 8-bit
   weights; NEureka, derived from NE16, is the neural engine (N-EUREKA) of Siracusa, a TSMC 16 nm SoC in a JSSC
   paper, with 3x3 dense, 3x3 depthwise and 1x1 convolutions, 8-bit activations, 2- to 8-bit weights and 8-bit
   requantized or 32-bit outputs. The Siracusa paper normalizes its efficiency to 0% weight sparsity and does not
   describe skipping zeros (checked in its first half), so skipping 2:4 zeros is what the hand-written coprocessor
   adds. That NE16 is GAP9's neural engine is suggested by pulp-nnx (NE16 runs with GreenWaves' `gap_sdk`) and a
   CASES '23 GAP9 paper, but no source read says it directly, so it is not claimed.
9. **CORE-V-XIF as the shape of the `dot4` handshake.** The eXtension Interface consists of compressed, issue,
   register, commit and result interfaces; the memory interfaces are "not included in this version of the
   specification". The issue response says whether the instruction is accepted and whether the unit will write
   back `rd`. Commit has no ready signal; with `commit_kill` it kills the offloaded instruction and every newer
   one. The result interface is valid / ready and carries `hartid`, `id`, `data`, `rd` and `we`. CVA6 has a
   `CvxifEn` configuration bit and an example coprocessor (`core/cvxif_example`) whose ALU only adds (ADD,
   DOUBLE_RS1 / RS2, three-source adds on R4-type encodings, one that always writes x10): a template for wiring,
   not a functional unit. The `dot4` valid / ready interface uses the same issue / result split, without commit
   (a single-cycle core has no speculation to kill), the register interface or the full parameter set, so a
   multi-cycle unit, the hls4ml design or the coprocessor can sit behind it later without changing the core's side.
10. **One configuration structure, as in CVA6.** CVA6's `config_pkg.sv` has a user-facing `cva6_user_cfg_t` (for
    example `XLEN`, `CvxifEn`) from which the full `cva6_cfg_t` is derived (`NrPMPEntries`, `BTBEntries`,
    `PerfCounterEn`, ...), and its CI builds 35 named targets under `config/target/`. The switch for `dot4` (11/29)
    and the ASIC configuration file (5/1) are fields of one package read by the RTL and the scripts, and each
    measured configuration gets a name.
11. **Standard HPM counters.** CVA6 has six programmable counters (`MHPMCounterNum = 6` in `ariane_pkg.sv`) from
    `mhpmcounter3` up, each with a 5-bit event select in `mhpmevent` (for example `5'b00001` is an
    instruction-cache miss). The event counters (5/8) use the standard CSR numbers and event-select form, so the
    same C code reads them on every build.
12. **Tandem simulation with Spike, next to this project's retire comparison.** CVA6's regression runs riscv-tests,
    riscv-dv programs and riscv-arch-test (`verif/regress/dv-riscv-arch-test.sh`) on its Verilator test harness and
    on Spike. With `SPIKE_TANDEM` set, `cva6.py` compares the core with Spike as the reference and reports
    "mismatches and ... matches"; the core can also write a commit log "which matches spike's commit log format for
    easier trace comparison", and it has an RVFI port. Whether the arch-test script runs in CI was not checked. This
    project keeps comparing the `retire_*` ports with its own golden model per instruction; two things are taken:
    the retire trace is also written in Spike's commit-log format, so Spike can be a second reference without
    changes to the golden model, and riscv-arch-test is a second acceptance step after rv32ui.

Not taken: the CVA6 and CV32E40P RTL, the PULP cluster and its interconnect, Snitch's stream semantic registers and
FREP (related work for the coupling comparison), common_cells (it overlaps BaseJump STL, see "Reused components"),
Bender (git submodules are used instead), the full CORE-V-XIF, and DORY's tool itself. pulp-platform's `axi`
library is a reference to read when the ZedBoard's AXI-Lite slave is written, not a dependency.

## Ideas taken from Ibex, VexRiscv and CFU Playground

Reviewed on 2026-11-22 and checked the same day against the sources: Ibex's README, `rtl/` listing,
`ibex_configs.yaml`, `rtl/ibex_tracer.sv` and `examples/simple_system/README.md`; VexRiscv's README (including the
area table and the "Add a custom instruction" section); CFU Playground's README and its overview and interface pages
(cfu-playground.readthedocs.io); and the README and `spec/intro.adoc` of the proposed Composable Custom Extensions
(github.com/grayresearch/CX). Item 6 was checked later the same day against the source: CFU Playground's
`proj/proj_template_v/cfu.v`, `python/amaranth_cfu/cfu.py` and `common/src/cfu.h`, and VexRiscv's
`src/main/scala/vexriscv/plugin/CfuPlugin.scala` (branch `master`), then CFU Playground's
`third_party/SaxonSoc/riscv.h` and `soc/vexriscv/src/main/scala/vexriscv/GenCoreDefault.scala`. Not read: Ibex's
`ibex_top_tracing.sv` and the CX specification PDF; points that depend on them are marked as unchecked.

Ibex (lowRISC) is a small RV32I / RV32E core (with optional M, C and B) in SystemVerilog: the `small` configuration
in `ibex_configs.yaml` is a "Two-stage pipeline" (`WritebackStage : 0`), `maxperf` a "Three-stage pipeline".
VexRiscv is written in SpinalHDL, a Scala library; "Nearly everything is plugin based", and its pipeline has 2 to 5
or more stages. CFU Playground (Google) is "a framework for playing with custom opcodes to accelerate TensorFlow Lite
for Microcontrollers", built on LiteX and VexRiscv, with the Arty A7 as the default board. No RTL is taken from any
of them (see "Reused components"); VexRiscv could not be used directly anyway, since its Verilog is generated from
Scala. Their structure, test harness and interfaces do apply.

1. **Ibex's package and decoder split, for the SystemVerilog core (now).** Ibex keeps the opcodes, ALU operations
   and other encodings as enums in `ibex_pkg.sv`, and `ibex_decoder.sv` only turns an instruction into control
   signals. The `sv-random` core's package and decoder follow the same split: the decoder computes nothing, so its
   output can be checked against the golden model's decode field by field.
2. **A character output next to TOHOST (before the random tests).** Ibex's simple system has "a basic peripheral
   to write ASCII output to a file and halt simulation": ASCII out at `0x20000`, simulator halt at `0x20008`, and a
   machine timer (`mtime` / `mtimecmp`) at `0x30000`. This project already ends a run with a store to TOHOST
   (`0x8000_0000`, `sw/c/mmio.h`); what it lacks in simulation is a character output, so a failing C test can print
   which check failed instead of only a test number. Added on 2026-11-22 (branch `sim-putc`): PUTC at
   `0x8000_0010`, `sim_putc` / `sim_puts` / `sim_puthex` in `sw/c/mmio.h`, printed as `OUT <name>: <text>` by
   `tb/tb_core.v` and `sw/iss.py`, and ignored by `fpga/rtl/soc.v` (whose decode now checks address bits [30:4],
   so the new address no longer aliases TOHOST). The new test program exposed a linker bug: `__bss_start` was
   not word aligned, so `crt0`'s word stores were misaligned when `.rodata` had an odd length (Spike stopped; the
   golden model rounded the address down and overwrote the last byte of `.rodata`); `sw/c/link.ld` now aligns
   it. The timer is not needed: the core has no interrupts.
3. **Ibex's tracer as an example of building the trace line.** `ibex_tracer.sv` "takes execution information from
   the RISC-V Verification Interface (RVFI)" and writes `trace_core_<HARTID>.log`, one line per retired instruction
   with six tab-separated columns (time, cycle, PC, instruction, decoded form, registers and memory accessed). The
   trace here stays in Spike's commit-log format (item 12 of the PULP and CVA6 section); Ibex's tracer is read only
   to see which signals make up each column. Since the tracer reads RVFI, once the RVFI wrapper (next item) exists
   the trace writer can read the wrapper instead of internal signals.
4. **Ibex's RVFI ports as the reference for the RVFI wrapper (5/22 to 5/29).** Already planned (item 2 of the
   OpenTitan section). Ibex's `rvfi_*` ports are the closest example for a small core's wrapper; how Ibex wires them
   internally (`ibex_top_tracing.sv`) was not checked.
5. **Named configurations, as in `ibex_configs.yaml` (5/1).** Ibex names each parameter set (`small`, `opentitan`,
   `maxperf`, ...; the README's "micro" column is not a key in the file). This is the same idea as item 10 of the
   PULP and CVA6 section: the ASIC configuration files (5/1) give every measured configuration a name, so a row in
   a results table points to one file.
6. **The CFU Playground interface as a reference for the `dot4` handshake (11/26 to 11/27).** "When the CPU
   executes that op code, it passes the contents of two registers to the CFU, waits for a response and puts the
   result back into a third register." The Verilog template (`proj/proj_template_v/cfu.v`, `module Cfu`) has
   these ports:

   | Port | Direction | Width |
   | --- | --- | --- |
   | `cmd_valid` | in | 1 |
   | `cmd_ready` | out | 1 |
   | `cmd_payload_function_id` | in | 10 |
   | `cmd_payload_inputs_0`, `cmd_payload_inputs_1` | in | 32 each |
   | `rsp_valid` | out | 1 |
   | `rsp_ready` | in | 1 |
   | `rsp_payload_outputs_0` | out | 32 |
   | `reset`, `clk` | in | 1 |

   The 10-bit function ID is {funct7, funct3}: the Amaranth base class (`python/amaranth_cfu/cfu.py`) takes funct3
   from bits [2:0] and funct7 from bits [9:3]. `common/src/cfu.h` encodes the instructions as R-type on custom-0
   (`opcode_R(CUSTOM0, funct3, funct7, rs1, rs2)`); `cfu_op0` to `cfu_op7` fix funct3 = 0 to 7 and the caller
   gives funct7. `riscv.h` is not in `common/src` but in `third_party/SaxonSoc/riscv.h` (copied from SpinalHDL's
   SaxonSoc, MIT license): it sets `CUSTOM0` to `0x0B` and `CUSTOM1` to `0x2B`, and `opcode_R` emits the standard
   R-type layout with `.word` (opcode | rd << 7 | rs1 << 15 | rs2 << 20 | funct3 << 12 | funct7 << 25), turning
   register names into numbers with a table of `.set regnum_*` directives; rs1 and rs2 are `"r"` inputs and the
   result is the `"=r"` output in rd.

   Handshake: the template, a combinational CFU, ties `rsp_valid = cmd_valid` and `cmd_ready = rsp_ready`
   ("Trivial handshaking for a combinational CFU"). The Amaranth class keeps `cmd_ready` at 1 while it waits for a
   command, raises `rsp_valid` when the instruction is done, and if `rsp_ready` is low it stores the result and
   holds `rsp_valid` until the CPU takes it ("Instruction has completed, but the CPU isn't ready to receive the
   result"). On the CPU side, VexRiscv's `CfuPlugin` stalls while `cmd_valid && !cmd_ready` and until `rsp_valid`;
   `rsp_ready` is not tied to 1 but is `!arbitration.isStuckByOthers`. Which instruction bits form the function ID
   is a plugin parameter (`encodings`, each a masked literal and bit ranges), not fixed in that file. CFU
   Playground sets it in `GenCoreDefault.scala`: one R-type encoding, `M"-------------------------0001011"` (every
   custom-0 instruction goes to the CFU) with `functionId = List(14 downto 12, 31 downto 25)` and
   `CFU_FUNCTION_ID_W = 10`, the same {funct7, funct3} as the Amaranth class; an I-type encoding (opcode
   `0101011`, immediate as the second operand) is commented out. The plugin is built with `stageCount = 1` and
   `allowZeroLatency = true`, so a CFU may answer in the same cycle, as a single-cycle `dot4` does.

   This project's encoding already matches: `dot4`, `max4` and `requant` are R-type on custom-0 (`0001011`) with
   funct7 = 0 and funct3 = 0, 1 and 2 (`sw/iss.py`, `DOT4_OPCODE = 0x0B`), which are CFU function IDs 0, 1 and
   2; the 2:4 instruction `sdot8` uses custom-1 (`0x2B`), CFU Playground's `CUSTOM1`. The valid / ready
   interface of `dot4` (11/26 to 11/27) takes the same eight signals: a command with a function ID and two
   operands, a response with one result, each with its own handshake. The single-cycle core can tie `rsp_ready` to
   1, but the unit keeps the "result waiting" state of the Amaranth class, so it needs no change behind a pipelined
   core or a bus.
7. **CFU Playground and the CX proposal as related work for the coupling comparison.** CFU Playground is the
   closest published example of the tightly coupled point (custom instructions in a soft core, on an Artix-7 board,
   for TFLM kernels). The difference to state in the SOP and README: here the core is written from scratch, the
   workload is one layer of a real medical model with bit-exact checks against PyTorch, and the same block is also
   taken through an ASIC flow and compared with a coprocessor and a standalone hls4ml design. The CX proposal
   (Jan Gray, "Draft Proposed", not a RISC-V International work product) standardizes such units: custom functions
   "of up to two operands", selected by CXU, function and state IDs, at "feature levels" from combinational to
   "variable latency CXUs with flow control". `dot4` with valid / ready is a variable-latency unit with flow
   control in those terms. Whether the levels have names such as L0 / L1 / L2 is in the CX specification PDF or its
   design-rationale slides, which were not read.
8. **VexRiscv's Artix-7 numbers as an outside reference in the results table (12/1 to 12/20).** The README lists,
   synthesized "as toplevel on the fastest speed grade": "VexRiscv small (RV32I, 0.52 DMIPS/MHz, no datapath
   bypass, no interrupt) -> Artix 7 -> 243 MHz 504 LUT 505 FF", the same with interrupts at 240 MHz / 556 LUT /
   566 FF, and "small and productive (RV32I, 0.82 DMIPS/MHz)" at 232 MHz / 816 LUT / 534 FF. They are quoted next
   to this core's numbers only with that context: VexRiscv is pipelined and measured as a bare core on the fastest
   speed grade, while this core is single-cycle and the Nexys A7 build includes memory and I/O (the core-only path
   and the `MEM_KIB=8` Fmax are the closer comparison).
9. **VexRiscv's `SimdAddPlugin` as a short example of adding a custom instruction.** It decodes with a masked
   literal (`M"0000011----------000-----0110011"`, `-` = don't care), adds four 8-bit lanes in Execute, and has its
   own regression (`CUSTOM_SIMD_ADD=yes`). The pattern matches this project's: one decoder entry, one functional
   unit, one directed test. It is read, not copied.

Extension (decided 2026-11-22, after 2/20, no fixed date): **Ibex and VexRiscv as baselines.** Generated Verilog of
Ibex (`small`) and VexRiscv (a small RV32I configuration, plus one with a CFU-style unit if time allows) runs the
same U-Net block on the Nexys A7 and, for Ibex, through the same ASIC flow, giving cycles, LUT / FF / DSP, Fmax and
energy per MAC next to this core with and without `dot4`. This does not break the rule in "Reused components": the
baselines are only measured, never part of this project's design, kept outside `rtl/` (for example under
`baselines/` with each project's license), and credited in the README.

## Ideas taken from TheHuzz, HyPFuzz and MABFuzz (and Polar Sparsity)

Read in full on 2026-11-25: TheHuzz (Kande et al., USENIX Security 2022), HyPFuzz (Chen et al., USENIX
Security 2023), MABFuzz (Gohil et al., DATE 2024) and PSOFuzz (Chen et al., ICCAD 2023) from JV Rajendran's
SETH lab at Texas A&M, and Polar Sparsity (Shrestha et al., NeurIPS 2025) from Narasimha Reddy's group.

**What the fuzzers do.** TheHuzz runs short tests (configuration instructions that are never mutated, then
20 test instructions) on the RTL and on a golden reference model (Spike), compares the traces, and keeps a
mutant only if it reaches new code coverage (statement, branch, toggle, expression, condition, FSM, from
the simulator). Its twelve mutation operators are AFL-style: bit flips of 1, 2, 4, 8 and 16 bits and byte
arithmetic on the data bits only (M0-M7), a random byte, delete (NOP), clone, and an opcode overwrite
(M8-M11). MABFuzz keeps TheHuzz and only changes which seed to mutate next: 10 seeds are the arms of a
bandit (epsilon-greedy, UCB1 or EXP3 with eta = 0.1), the reward is 0.25 x coverage new to that arm +
0.75 x coverage new to all arms, and an arm with no new coverage in its last 3 pulls is replaced by a new
seed. HyPFuzz switches to JasperGold when the fuzzer's rate of new coverage over its last 100 tests drops
below the formal tool's average rate, and turns the formal tool's input trace for an uncovered branch point
(chosen in the module with the most uncovered points) into a new seed. The reported gains are on code
coverage of CVA6, Rocket and BOOM: MABFuzz reaches TheHuzz's coverage at least 2.98x faster on CVA6 and
Rocket and gives nothing on BOOM, where TheHuzz is already above 95%; HyPFuzz is 11.68x faster than
TheHuzz on average and found 3 new CVA6 bugs.

**What was built here (`sw/fuzz.py`, `make fuzz`).** The same loop for this core, with three changes:
(1) every mutant is repaired into a legal, terminating RV32I instruction (no traps, CSRs or ECALL on this
core; loads and stores through t6 inside the data buffer, forward branches and JAL only, rd never t5 / t6),
so TheHuzz's illegal-instruction bugs are out of scope; (2) coverage is ISA-level functional coverage from
the golden model's trace (mnemonic x rd = x0, operand and immediate value classes, rs1 = rs2, result class,
branch taken / not taken, byte lane, and read-after-write pairs between consecutive instructions), because
the core is not finished and Icarus has no code coverage; (3) the check today is the golden model against
Spike; `--ref core --sim build/sim_core_retire` checks the core against the golden model once it runs.
Policies: `random` (a fresh random test each time, as `random-test`), `rr` (TheHuzz mutation, seeds in
round robin), `ucb` and `exp3` (MABFuzz, its parameters), and `ucb-dep`, which adds an operator of ours
(M12: the next test instruction reads this one's rd, e.g. a load followed by its use).

**Evaluation (`sw/fuzz_bugs.py`, 2026-11-25).** Rule set before the run: `make fuzz` defaults to the
policy with the most bins after 1,600 tests. Three seeds per policy; bug detection = tests until the first
mismatch with Spike, with one of ten bugs injected into a copy of the golden model, 800 tests at most
(results in steps of 14, the batch size).

| policy | bins after 1,600 tests (mean, 3 seeds) |
| --- | ---: |
| random | 1,233 |
| ucb | 764 |
| ucb-dep | 763 |
| rr | 745 |
| exp3 | 707 |

| injected bug | random | rr | ucb | exp3 | ucb-dep |
| --- | ---: | ---: | ---: | ---: | ---: |
| B1 SRA by 31 shifts in zeros | 127 (3/3) | 15 (2/3) | 15 (2/3) | 106 (2/3) | 15 (2/3) |
| B2 SLTIU zero-extends its immediate | 4 (3/3) | 77 (3/3) | 77 (3/3) | 29 (3/3) | 82 (3/3) |
| B3 LH from lane 2 zero-extends | 4 (3/3) | 43 (3/3) | 43 (3/3) | 15 (3/3) | 43 (3/3) |
| B4 BGE not taken when equal | 14 (3/3) | 127 (3/3) | 127 (3/3) | 295 (3/3) | 127 (3/3) |
| B5 SLT wrong when rs1 = INT_MIN | 149 (3/3) | 270 (1/3) | 328 (1/3) | 506 (2/3) | 436 (2/3) |
| B6 load result not visible to the next rs1 | 11 (3/3) | 192 (2/3) | 320 (2/3) | 113 (1/3) | 44 (3/3) |
| B7 SB to lane 3 writes lane 0 | 6 (3/3) | 15 (3/3) | 15 (3/3) | 43 (3/3) | 15 (3/3) |
| B8 SUB writes x0 | 26 (3/3) | 85 (1/3) | 205 (3/3) | 243 (2/3) | 85 (1/3) |
| B9 AUIPC adds pc + 4 | 1 (3/3) | 15 (3/3) | 15 (3/3) | 14 (3/3) | 15 (3/3) |
| B10 SRLI by 0 returns 0 | 5 (3/3) | 150 (2/3) | 150 (2/3) | 717 (3/3) | 426 (2/3) |

Median tests to detection over the seeds that found it (found / seeds). The correct golden model matched
Spike on all 24,000 coverage tests.

- **Random tests win here, so `make fuzz` defaults to `random` and `random-test` stays the main random
  check.** Random found every bug in every seed, 9 of 10 faster than any mutation policy. The mutation
  policies keep a seed's register and data values and change only 1-3 instructions, so they reach few new
  operand classes, and single-instruction corner cases need exactly that. This is not a contradiction of
  the papers: their gains are on RTL code coverage of large out-of-order cores, where a test has to build up
  deep microarchitectural state and keeping a good prefix pays.
- **MABFuzz's seed selection did not help over round robin** (ucb 764 bins against rr 745, exp3 707).
- **The dependency operator helps where it should**: among the mutation policies, the load-use bug B6 drops
  from 320 tests (ucb) to 44 (ucb-dep) and is found in 3 of 3 seeds instead of 2. Random still finds it in 11.

**When to come back to it.**
1. When the core passes rv32ui: run `--ref core`, and add Verilator `--coverage` (line and toggle) of the
   core as the feedback instead of the ISA bins. That is the setting in which TheHuzz and MABFuzz reported
   their gains, and it shows which RTL the random tests never reach (the testplan item from OpenTitan above).
2. For the 5-stage version (Next steps): stalls and forwarding are deep state of the kind mutation helps
   with, and read-after-write at distances 1-3 is what M12 generates; re-run this evaluation there.
3. For riscv-formal (2026-05-22 to 05-29): HyPFuzz's rule is a ready schedule: run random tests until the
   rate of new coverage over the last 100 tests falls below the formal tool's average rate, then give the
   formal tool the uncovered points of the module with the most of them.

**Polar Sparsity (Reddy's group).** In batched LLM decoding, MLP activation sparsity disappears as the
batch grows (a neuron is kept if any sequence in the batch needs it, and weight reads are already shared by
the batch), while attention-head sparsity stays, because each sequence reads its own KV cache and that cost
grows with the batch; their head-sparse attention kernel reaches 2.8x at 30% of the heads and the whole
system up to 2.2x. The same lesson as the dental 2:4 result: skipping work helps only when it removes the
cost that dominates (here the memory traffic of attention), not when it removes work that is already cheap.

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
- During the one-layer board run (12/9 to 12/16): after `decoders.3.block.3`, measure the held-out layer
  `decoders.3.block.0` (weights exported, golden model passes; item 4 of the ASU section) and report the cost
  model's error on it.
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
- Ibex and VexRiscv as measured baselines on the same U-Net block (FPGA, and Ibex through the ASIC flow); see
  "Ideas taken from Ibex, VexRiscv and CFU Playground". After 2/20, no fixed date.
- A pipelined core, measured for what it changes about `dot4`, not as a sweep of pipeline depths (decided
  2026-11-22). Depth trade-offs are known (more stages raise Fmax and lose CPI to hazards and branches), and the
  project's question is coupling, so one pipelined version (5 stages) is built and the other depths are quoted:
  VexRiscv's Artix-7 table (item 8 of the Ibex section) and, if cheap, Ibex `small` (2 stages) and `maxperf`
  (3 stages) as extra rows in the baseline comparison above. Measured on the same U-Net block, with and without
  `dot4`, for the single-cycle and the 5-stage core: cycles, Fmax, LUT / FF / DSP and time per block (cycles /
  Fmax). The question to answer: does `dot4` (four 8-bit products and their sum) become the critical path of the
  execute stage? If it does, compare a single-cycle `dot4` (and the Fmax it costs) with a two-cycle `dot4` behind
  the valid / ready interface, where the core waits as VexRiscv's `CfuPlugin` does; the unit itself should not
  change, which is the reason its interface follows CFU Playground's (item 6 of the Ibex section). The RVFI
  wrapper (5/22 to 5/29) matters more here, since retire order and timing are no longer one instruction per
  cycle. After 2/20, together with the baseline comparison, so that one table answers both the depth and the
  custom-instruction questions; not before the SOP.
- Gemmini in simulation (Chipyard, Verilator) as a reference point for the loosely-coupled end, run on the same
  convolution layer for cycle counts. Optional and only if a paper or the SOP needs it: the install is large (many GB
  and a conda environment, with 10 GB of memory in WSL), and it is not this project's own design.
