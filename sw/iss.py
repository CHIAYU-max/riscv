#!/usr/bin/env python3
"""RV32I instruction-set simulator: the golden model for rv32i_core.

Runs a program hex (same file as tb/tb_core.v, one little-endian word per line) on the
same memory map as the testbench and reports PASS / FAIL / ILLEGAL / BADADDR / TIMEOUT.
With --trace it writes the reference trace that sw/trace_diff.py compares against
the testbench's trace (see README.md, "Golden model and trace comparison"):

  R pc=<pc> insn=<insn> rd=<rd> val=<value>     one line per retired instruction
                                                  (rd=00 val=00000000 when nothing is written)
  S addr=<addr> data=<data> strb=<strb>         one line per store, data already in its byte lanes

With --profile it counts the instructions executed in each function, using the labels in the
program's objdump file; libgcc helpers (names starting with "__", e.g. __mulsi3) count toward the
function that called them, so each function's count includes the work it delegates.

usage: sw/iss.py build/tests/add.hex [--trace build/trace/add.ref] [--max-steps n]
                 [--profile build/c/fib.dump]
"""
import argparse
import bisect
import re
import sys

MEM_BYTES = 64 * 1024
TOHOST = 0x8000_0000
MASK = 0xFFFF_FFFF

# dot4 custom instruction (only with --dot4): custom-0 opcode 0001011, R-type, funct3 = 0, funct7 = 0,
# rd = sum over the four byte lanes of rs1[i] * rs2[i]. rs1 holds unsigned activations (u8) and rs2 signed
# weights (s8), as in the OpenVINO INT8 U-Net (activations after ReLU are u8, weights symmetric s8) and
# Intel VNNI vpdpbusd. Keep in sync with sw/c/dot4.h and the Makefile's DOT4_ACT.
DOT4_OPCODE = 0x0B
DOT4_RS1_SIGNED = False
DOT4_RS2_SIGNED = True

# Two more custom-0 instructions for the rest of a U-Net block (also only with --dot4; R-type, funct7 = 0).
# Keep in sync with sw/c/nnops.h.
#   max4    funct3 = 1   rd[i] = max(rs1[i], rs2[i]) per unsigned byte lane (2x2 max pooling on u8 activations)
#   requant funct3 = 2   rd = clamp(((rs1 * M + round) >>> shift) + zp, 0, 255), rs1 = signed 32-bit accumulator,
#                        rs2 = {zp[31:24], 3'b0, shift[20:16], M[15:0]}: u16 multiplier, shift 0..31, u8 zero point;
#                        round = 1 << (shift - 1) (0 when shift = 0), i.e. round half up. Clamping at 0 is the ReLU
#                        when the output zero point is 0. Bits [23:21] are ignored.
MAX4_FUNCT3 = 1
REQUANT_FUNCT3 = 2


def sext(value, bits):
    sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)


def byte_lane(word, i, signed):
    value = word >> (8 * i) & 0xFF
    return sext(value, 8) if signed else value


def max4(a, b):
    return sum(max(byte_lane(a, i, False), byte_lane(b, i, False)) << (8 * i) for i in range(4))


def requant(acc, params):
    m, shift, zp = params & 0xFFFF, params >> 16 & 31, params >> 24 & 0xFF
    t = sext(acc, 32) * m                       # exact 48-bit product
    if shift:
        t = (t + (1 << (shift - 1))) >> shift   # Python >> on ints is arithmetic
    return min(max(t + zp, 0), 255)


class Halt(Exception):
    def __init__(self, result, detail=0):
        super().__init__(result)
        self.result, self.detail = result, detail


class RV32I:
    def __init__(self, hex_path, dot4=False, mul=False):
        self.dot4, self.mul = dot4, mul
        self.mem = bytearray(MEM_BYTES)
        with open(hex_path) as f:
            words = [int(line, 16) for line in f if line.strip()]
        for i, word in enumerate(words[:MEM_BYTES // 4]):
            self.mem[4 * i:4 * i + 4] = word.to_bytes(4, "little")
        self.x = [0] * 32
        self.pc = 0
        self.trace = []

    # Memory: RAM at 0, reads elsewhere return 0 (as in tb_core.v)
    def load_word(self, addr):
        if addr < MEM_BYTES:
            base = addr & ~3
            return int.from_bytes(self.mem[base:base + 4], "little")
        return 0

    def store(self, addr, data, strb):
        self.trace.append(f"S addr={addr:08x} data={data:08x} strb={strb:x}")
        if addr == TOHOST:
            raise Halt("PASS") if data == 1 else Halt("FAIL", data >> 1)
        if addr < MEM_BYTES:
            base = addr & ~3
            for lane in range(4):
                if strb >> lane & 1:
                    self.mem[base + lane] = data >> (8 * lane) & 0xFF
        elif not addr >> 31:
            raise Halt("BADADDR")
        # other I/O (LED, SEG): the store is only traced

    def step(self):
        pc, x = self.pc, self.x
        if pc >= MEM_BYTES or pc & 3:
            raise Halt("BADADDR")
        insn = self.load_word(pc)
        op, rd, f3 = insn & 0x7F, insn >> 7 & 31, insn >> 12 & 7
        rs1, rs2, f7 = x[insn >> 15 & 31], x[insn >> 20 & 31], insn >> 25
        imm_i = sext(insn >> 20, 12)
        imm_s = sext((insn >> 25) << 5 | (insn >> 7 & 31), 12)
        imm_b = sext((insn >> 31 & 1) << 12 | (insn >> 7 & 1) << 11 | (insn >> 25 & 0x3F) << 5 | (insn >> 8 & 0xF) << 1, 13)
        imm_u = insn & 0xFFFF_F000
        imm_j = sext((insn >> 31 & 1) << 20 | (insn >> 12 & 0xFF) << 12 | (insn >> 20 & 1) << 11 | (insn >> 21 & 0x3FF) << 1, 21)
        next_pc, value = pc + 4, None

        if op == 0x37:                                  # LUI
            value = imm_u
        elif op == 0x17:                                # AUIPC
            value = pc + imm_u
        elif op == 0x6F:                                # JAL
            value, next_pc = pc + 4, pc + imm_j
        elif op == 0x67 and f3 == 0:                    # JALR
            value, next_pc = pc + 4, (rs1 + imm_i) & ~1
        elif op == 0x63:                                # BRANCH
            s1, s2 = sext(rs1, 32), sext(rs2, 32)
            taken = {0: rs1 == rs2, 1: rs1 != rs2, 4: s1 < s2, 5: s1 >= s2, 6: rs1 < rs2, 7: rs1 >= rs2}.get(f3)
            if taken is None:
                raise Halt("ILLEGAL")
            if taken:
                next_pc = pc + imm_b
        elif op == 0x03:                                # LOAD
            addr = (rs1 + imm_i) & MASK
            word = self.load_word(addr) >> (8 * (addr & 3))
            if f3 == 0:
                value = sext(word & 0xFF, 8)
            elif f3 == 1:
                value = sext(word & 0xFFFF, 16)
            elif f3 == 2:
                value = word
            elif f3 == 4:
                value = word & 0xFF
            elif f3 == 5:
                value = word & 0xFFFF
            else:
                raise Halt("ILLEGAL")
        elif op == 0x23:                                # STORE
            addr = (rs1 + imm_s) & MASK
            lane = addr & 3
            if f3 == 0:
                data, strb = (rs2 & 0xFF) << (8 * lane), 1 << lane
            elif f3 == 1:
                data, strb = (rs2 & 0xFFFF) << (8 * (lane & 2)), 3 << (lane & 2)
            elif f3 == 2:
                data, strb = rs2, 0xF
            else:
                raise Halt("ILLEGAL")
            # a store retires (R line) and then writes memory (S line); a TOHOST store ends the run here
            self.trace.append(self.retire_line(pc, insn, 0, 0))
            self.pc = next_pc
            self.store(addr, data & MASK, strb)
            return
        elif op == 0x13:                                # OP-IMM
            shamt = insn >> 20 & 31
            if f3 == 0:
                value = rs1 + imm_i
            elif f3 == 2:
                value = int(sext(rs1, 32) < imm_i)
            elif f3 == 3:
                value = int(rs1 < (imm_i & MASK))
            elif f3 == 4:
                value = rs1 ^ imm_i
            elif f3 == 6:
                value = rs1 | imm_i
            elif f3 == 7:
                value = rs1 & imm_i
            elif f3 == 1 and f7 == 0:
                value = rs1 << shamt
            elif f3 == 5 and f7 == 0:
                value = rs1 >> shamt
            elif f3 == 5 and f7 == 0x20:
                value = sext(rs1, 32) >> shamt
            else:
                raise Halt("ILLEGAL")
        elif op == 0x33 and f7 == 1 and f3 <= 3 and self.mul:   # MUL, MULH, MULHSU, MULHU (only with --mul)
            s1, s2 = sext(rs1, 32), sext(rs2, 32)
            value = (rs1 * rs2, s1 * s2 >> 32, s1 * rs2 >> 32, rs1 * rs2 >> 32)[f3]
        elif op == 0x33:                                # OP
            shamt = rs2 & 31
            value = {
                (0, 0): lambda: rs1 + rs2,
                (0, 0x20): lambda: rs1 - rs2,
                (1, 0): lambda: rs1 << shamt,
                (2, 0): lambda: int(sext(rs1, 32) < sext(rs2, 32)),
                (3, 0): lambda: int(rs1 < rs2),
                (4, 0): lambda: rs1 ^ rs2,
                (5, 0): lambda: rs1 >> shamt,
                (5, 0x20): lambda: sext(rs1, 32) >> shamt,
                (6, 0): lambda: rs1 | rs2,
                (7, 0): lambda: rs1 & rs2,
            }.get((f3, f7), lambda: None)()
            if value is None:
                raise Halt("ILLEGAL")
        elif op == 0x0F:                                # FENCE: no-op
            pass
        elif op == DOT4_OPCODE and self.dot4 and f3 == 0 and f7 == 0:   # dot4 (custom-0)
            value = sum(byte_lane(rs1, i, DOT4_RS1_SIGNED) * byte_lane(rs2, i, DOT4_RS2_SIGNED) for i in range(4))
        elif op == DOT4_OPCODE and self.dot4 and f3 == MAX4_FUNCT3 and f7 == 0:      # max4 (custom-0)
            value = max4(rs1, rs2)
        elif op == DOT4_OPCODE and self.dot4 and f3 == REQUANT_FUNCT3 and f7 == 0:   # requant (custom-0)
            value = requant(rs1, rs2)
        else:                                          # SYSTEM (ecall, CSRs) and anything else
            raise Halt("ILLEGAL")

        if value is not None and rd != 0:
            x[rd] = value & MASK
            self.trace.append(self.retire_line(pc, insn, rd, x[rd]))
        else:
            self.trace.append(self.retire_line(pc, insn, 0, 0))
        self.pc = next_pc & MASK

    @staticmethod
    def retire_line(pc, insn, rd, value):
        return f"R pc={pc:08x} insn={insn:08x} rd={rd:02d} val={value:08x}"


class Profile:
    """Instruction counts per function, from the '<addr> <name>:' labels of an objdump -d file."""

    def __init__(self, dump_path):
        labels = []
        with open(dump_path) as f:
            for line in f:
                m = re.match(r"([0-9a-f]+) <([^>]+)>:$", line.strip())
                if m:
                    labels.append((int(m.group(1), 16), m.group(2)))
        labels.sort()
        self.starts = [addr for addr, _ in labels]
        self.names = [name for _, name in labels]
        self.counts = {}
        self.current = "?"

    def count(self, pc):
        i = bisect.bisect_right(self.starts, pc) - 1
        name = self.names[i] if i >= 0 else "?"
        if not name.startswith("__"):           # a libgcc helper counts toward its caller
            self.current = name
        self.counts[self.current] = self.counts.get(self.current, 0) + 1

    def report(self):
        total = sum(self.counts.values())
        for name, n in sorted(self.counts.items(), key=lambda item: -item[1]):
            print(f"  {name:<16} {n:>10,}  {100 * n / total:5.1f}%")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("hex")
    parser.add_argument("--name", default=None)
    parser.add_argument("--trace", help="write the reference trace to this file")
    parser.add_argument("--max-steps", type=int, default=1_000_000)
    parser.add_argument("--dot4", action="store_true", help="also decode the custom-0 instructions (dot4, max4, requant)")
    parser.add_argument("--mul", action="store_true", help="also decode MUL, MULH, MULHSU, MULHU (benchmark baselines only)")
    parser.add_argument("--profile", metavar="DUMP", help="print instructions per function, labels from this objdump file")
    args = parser.parse_args()
    name = args.name or args.hex.rsplit("/", 1)[-1].removesuffix(".hex")

    cpu = RV32I(args.hex, dot4=args.dot4, mul=args.mul)
    profile = Profile(args.profile) if args.profile else None
    steps = 0
    try:
        while steps < args.max_steps:
            if profile:
                profile.count(cpu.pc)
            cpu.step()
            steps += 1
        result, detail = "TIMEOUT", 0
    except Halt as halt:
        result, detail = halt.result, halt.detail
        steps += 1
    if args.trace:
        with open(args.trace, "w") as f:
            f.writelines(line + "\n" for line in cpu.trace)
    if result == "PASS":
        print(f"PASS    {name} ({steps} instructions)")
    elif result == "FAIL":
        print(f"FAIL    {name}: test case {detail} ({steps} instructions)")
    else:
        print(f"{result} {name}: pc 0x{cpu.pc:08x} ({steps} instructions)")
    if profile:
        profile.report()
    sys.exit(0 if result == "PASS" else 1)


if __name__ == "__main__":
    main()
