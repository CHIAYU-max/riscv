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

## INT4 experiment (golden model only)

To see what 4-bit weights and activations would buy on this core, the golden model has one more custom-0
instruction, `dot8` (funct3 = 3): eight u4 x s4 products summed into `rd`, nibble lane i = bits [4i+3:4i]. It is not
in the RTL. `sw/c/bench/block4.c` runs the same U-Net block as `block.c` with u4 activations and symmetric s4 weights
(-7..7) packed two per byte (`sw/c/gen_block.py --bits 4`); `requant` still clamps to 255, so the clamp to 15 is one
extra compare in software, and the pool phase packs the output back into nibbles for the next layer.
`make block4-iss` runs it next to the INT8 builds. The data is random, with the same ReLU / saturation split as the
INT8 tile (73 vs 74 of 128 outputs zero, 12 saturated), so these numbers say nothing about accuracy.

Golden-model instruction counts (2026-11-08), default tile (32 input channels, 4x4 outputs, 8 output channels,
36,864 MACs); "text" is code plus constant data (weights, activations), from `riscv64-unknown-elf-size`:

| Build | Total | conv | requant | pool | text (bytes) |
| --- | ---: | ---: | ---: | ---: | ---: |
| `block_nn` (INT8: dot4 + requant + max4) | 78,503 | 76,261 | 1,144 | 206 | 4,360 |
| `block_rb` (INT8, 2 x 4 register blocking) | 33,324 | 31,080 | 1,146 | 206 | 4,616 |
| `block_q4` (INT4: dot8 + requant + max4) | 44,699 | 42,179 | 1,553 | 188 | 2,652 |
| `block_q4rb` (INT4, 2 x 4 register blocking) | 19,447 | 16,927 | 1,553 | 188 | 2,932 |

- INT4 runs the block 1.76x (`block_nn` to `block_q4`) and 1.71x (`block_rb` to `block_q4rb`) faster in
  instructions, not 2x: the inner loop has the same 25 instructions and now does 64 MACs instead of 32, but the
  address arithmetic per kernel position and the requant phase do not shrink. With 64 input channels `block_q4rb`
  runs 73,728 MACs in 31,080 convolution instructions, exactly what `block_rb` needs for half the MACs.
- The software clamp to 15 adds about 3 instructions per output (requant 1,144 to 1,553). Bits [23:21] of the
  `requant` parameter word are unused and could select the output width instead.
- Memory matters more than speed on the Basys3: with 64 input channels and 8 output channels the INT8 block does
  not fit in the 8 KiB RAM (the linker reports `block_nn` 296 and `block_rb` 536 bytes over), while the INT4 one
  does (`block_q4` 4,420 bytes text, `block_q4rb` 4,668, both with 656 bytes bss).
  With 128 input channels neither fits.
- Not measured yet: the accuracy of a 4-bit U-Net on the dental X-rays (likely needs quantization-aware
  training), and the area of eight 4 x 4 multipliers against four 8 x 8 ones on the FPGA. INT4 rather than FP4 because a CNN with BN and ReLU
  has no large activation outliers, and an integer `dot8` feeds the existing integer `requant` directly.

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
- A small memory-mapped 3x3 convolution coprocessor with its own line buffer, compared with `dot4` on the same layer,
  to place the two approaches side by side with measured numbers.
- Gemmini in simulation (Chipyard) as a reference point for the loosely-coupled end.
