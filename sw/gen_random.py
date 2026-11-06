#!/usr/bin/env python3
"""Generate a random RV32I test program (assembly for the riscv-tests environment in sw/env).

The program has no expected result of its own: it is run on the core and on the golden model
(sw/iss.py) and the two traces are compared (sw/run_random.sh). To make register state visible
without the optional retire ports, it ends by storing x1..x31 to a signature area.

Contents, all with random registers and immediates (edge values are drawn more often):
  - every RV32I computational instruction (OP, OP-IMM, LUI, AUIPC), with x0 as a possible destination
  - loads and stores of every width, naturally aligned, inside a data buffer addressed through t6
  - branches, JAL and JALR, always forward (1..4 instructions ahead) so that every program ends;
    JALR offsets include odd ones to check that bit 0 of the target is cleared
  - FENCE (a no-op for this core)
  - with --custom: dot4, max4 and requant (custom-0, funct3 0 / 1 / 2)
t5 and t6 are reserved (jump target and data pointer) and never written by random instructions.

usage: sw/gen_random.py --out build/random/rand_1.S [--seed 1] [--length 300] [--custom]
"""
import argparse
import random

POOL = list(range(0, 30))                       # x0..x29 may be written; x30 (t5) and x31 (t6) are reserved
DATA_WORDS = 64                                 # 256-byte data buffer; t6 points at its middle
EDGE32 = [0, 1, 2, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFE, 0x0000FFFF, 0xFFFF0000,
          0x000000FF, 0x00000080, 0x0000007F, 0x00008000]
EDGE12 = [0, 1, -1, 2047, -2048, 2046, -2047, 0x7F, 0x80, -0x80]

OP = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
OP_IMM = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SHIFT_IMM = ["slli", "srli", "srai"]
LOADS = [("lb", 1), ("lh", 2), ("lw", 4), ("lbu", 1), ("lhu", 2)]
STORES = [("sb", 1), ("sh", 2), ("sw", 4)]
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]


class Gen:
    def __init__(self, rng, custom):
        self.rng, self.custom = rng, custom

    def src(self):
        # any register may be read, including the reserved t5 / t6
        return f"x{self.rng.randrange(32)}"

    def dst(self):
        return "x0" if self.rng.random() < 0.05 else f"x{self.rng.choice(POOL[1:])}"

    def imm12(self):
        return self.rng.choice(EDGE12) if self.rng.random() < 0.3 else self.rng.randint(-2048, 2047)

    def word(self):
        return self.rng.choice(EDGE32) if self.rng.random() < 0.3 else self.rng.getrandbits(32)

    def instruction(self, i, n):
        """Assembly for instruction slot i of n; label r_<i> marks its start."""
        rng = self.rng
        kinds = ["op"] * 6 + ["opimm"] * 5 + ["shift"] * 2 + ["lui", "auipc"] + ["load"] * 3 + ["store"] * 3 \
            + ["branch"] * 3 + ["jal", "jalr", "fence"] + (["custom"] * 3 if self.custom else [])
        kind = rng.choice(kinds)
        ahead = min(n, i + rng.randint(1, 4))          # forward target (r_<n> is the end label)
        if kind == "op":
            return [f"{rng.choice(OP)} {self.dst()}, {self.src()}, {self.src()}"]
        if kind == "opimm":
            return [f"{rng.choice(OP_IMM)} {self.dst()}, {self.src()}, {self.imm12()}"]
        if kind == "shift":
            shamt = rng.choice([0, 1, 31, 16]) if rng.random() < 0.4 else rng.randrange(32)
            return [f"{rng.choice(SHIFT_IMM)} {self.dst()}, {self.src()}, {shamt}"]
        if kind in ("lui", "auipc"):
            imm = rng.choice([0, 1, 0x7FFFF, 0x80000, 0xFFFFF]) if rng.random() < 0.3 else rng.randrange(1 << 20)
            return [f"{kind} {self.dst()}, {imm}"]
        if kind == "load":
            name, size = rng.choice(LOADS)
            off = rng.randrange(-DATA_WORDS * 2, DATA_WORDS * 2, size)
            return [f"{name} {self.dst()}, {off}(t6)"]
        if kind == "store":
            name, size = rng.choice(STORES)
            off = rng.randrange(-DATA_WORDS * 2, DATA_WORDS * 2, size)
            return [f"{name} {self.src()}, {off}(t6)"]
        if kind == "branch":
            a = self.src()
            b = a if rng.random() < 0.15 else self.src()   # equal operands now and then
            return [f"{rng.choice(BRANCHES)} {a}, {b}, r_{ahead}"]
        if kind == "jal":
            return [f"jal {self.dst()}, r_{ahead}"]
        if kind == "jalr":
            off = rng.choice([0, 0, 4, -4, 1, 3, -1, 2047, -2048])
            # t5 = target - off, so that off(t5) is the target; odd offsets check that bit 0 is cleared
            base = off & ~1
            return [f"la t5, r_{ahead}{-base:+d}", f"jalr {self.dst()}, {off}(t5)"]
        if kind == "fence":
            return ["fence"]
        f3 = rng.randrange(3)                            # dot4, max4, requant
        return [f".insn r 0x0B, {f3}, 0, {self.dst()}, {self.src()}, {self.src()}"]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", required=True)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--length", type=int, default=300, help="random instructions (not counting setup)")
    parser.add_argument("--custom", action="store_true", help="also use dot4, max4 and requant")
    args = parser.parse_args()
    rng = random.Random(args.seed)
    gen = Gen(rng, args.custom)

    out = [f"// generated by sw/gen_random.py --seed {args.seed} --length {args.length}"
           + (" --custom" if args.custom else ""),
           '#include "riscv_test.h"', "RVTEST_RV32U", "RVTEST_CODE_BEGIN",
           "  la t6, rnd_data + %d" % (DATA_WORDS * 2)]
    for r in POOL[1:]:
        out.append(f"  li x{r}, 0x{gen.word():08x}")
    for i in range(args.length):
        out.append(f"r_{i}:")
        out += [f"  {line}" for line in gen.instruction(i, args.length)]
    out.append(f"r_{args.length}:")
    out.append("  la t5, rnd_sig")
    out += [f"  sw x{r}, {4 * r}(t5)" for r in range(1, 32)]
    out += ["  RVTEST_PASS", "RVTEST_CODE_END", "", "  .data", "RVTEST_DATA_BEGIN", "  .align 4", "rnd_data:"]
    out += [f"  .word 0x{gen.word():08x}" for _ in range(DATA_WORDS)]
    out += ["rnd_sig:", "  .space 128", "RVTEST_DATA_END", ""]
    with open(args.out, "w") as f:
        f.write("\n".join(out))


if __name__ == "__main__":
    main()
