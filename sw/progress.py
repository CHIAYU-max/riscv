#!/usr/bin/env python3
"""Bring-up progress for rv32i_core: rv32ui tests grouped by the instructions they need.

The golden model (sw/iss.py) runs every test once and records which instructions it actually executes. A test
belongs to the first bring-up stage after which all of its instructions are implemented, so the stages say
which tests can pass once a group of instructions is written. With a simulator, every test also runs on the
core and the table shows how far the bring-up has got.

usage: python3 sw/progress.py [--sim build/sim_core] build/tests/*.hex
       (make progress runs this; make progress PLAN=1 prints the plan without a core)
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

# Bring-up order. Stage 0 is the first program (simple): li (LUI + ADDI), FENCE as a no-op and the TOHOST store
# (SW). Stage 1 adds what every other test uses to check results (BNE) and to spin after a failure (JAL).
STAGES = [
    ("0 first program", ["LUI", "ADDI", "SW", "FENCE"]),
    ("1 result checks", ["BNE", "JAL"]),
    ("2 ALU, immediate", ["ANDI", "ORI", "XORI", "SLTI", "SLTIU", "SLLI", "SRLI", "SRAI"]),
    ("3 ALU, register", ["ADD", "SUB", "AND", "OR", "XOR", "SLT", "SLTU", "SLL", "SRL", "SRA"]),
    ("4 branches and jumps", ["BEQ", "BLT", "BGE", "BLTU", "BGEU", "JALR", "AUIPC"]),
    ("5 loads and stores", ["LW", "LH", "LHU", "LB", "LBU", "SH", "SB"]),
]

BRANCH = {0: "BEQ", 1: "BNE", 4: "BLT", 5: "BGE", 6: "BLTU", 7: "BGEU"}
LOAD = {0: "LB", 1: "LH", 2: "LW", 4: "LBU", 5: "LHU"}
STORE = {0: "SB", 1: "SH", 2: "SW"}
OP_IMM = {0: "ADDI", 2: "SLTI", 3: "SLTIU", 4: "XORI", 6: "ORI", 7: "ANDI", 1: "SLLI"}
OP = {(0, 0): "ADD", (0, 0x20): "SUB", (1, 0): "SLL", (2, 0): "SLT", (3, 0): "SLTU", (4, 0): "XOR",
      (5, 0): "SRL", (5, 0x20): "SRA", (6, 0): "OR", (7, 0): "AND"}


def mnemonic(insn):
    op, f3, f7 = insn & 0x7F, insn >> 12 & 7, insn >> 25
    if op == 0x37:
        return "LUI"
    if op == 0x17:
        return "AUIPC"
    if op == 0x6F:
        return "JAL"
    if op == 0x67:
        return "JALR"
    if op == 0x63:
        return BRANCH.get(f3, "?")
    if op == 0x03:
        return LOAD.get(f3, "?")
    if op == 0x23:
        return STORE.get(f3, "?")
    if op == 0x13:
        if f3 == 5:
            return "SRAI" if f7 == 0x20 else "SRLI"
        return OP_IMM[f3]
    if op == 0x33:
        return OP.get((f3, f7), "?")
    if op == 0x0F:
        return "FENCE"
    return "?"


def needed(hex_path):
    """Instructions the golden model executes in this program (a store's R line comes before its S line)."""
    with tempfile.TemporaryDirectory() as tmp:
        ref = os.path.join(tmp, "ref")
        run = subprocess.run([sys.executable, "sw/iss.py", hex_path, "--trace", ref], capture_output=True, text=True)
        if not run.stdout.startswith("PASS"):
            sys.exit(f"golden model does not pass {hex_path}: {run.stdout.strip()}")
        names = set()
        with open(ref) as f:
            for line in f:
                m = re.match(r"R pc=\w+ insn=(\w+)", line)
                if m:
                    names.add(mnemonic(int(m.group(1), 16)))
    # FENCE does not retire a register write but is executed by every test (RVTEST_PASS)
    return names | {"FENCE"}


def stage_of(names):
    have = set()
    for i, (_, group) in enumerate(STAGES):
        have |= set(group)
        if names <= have:
            return i
    sys.exit(f"instructions outside the stages: {sorted(names - have)}")


def run_core(sim, hex_path):
    name = os.path.basename(hex_path)[:-4]
    out = subprocess.run(["vvp", "-n", sim, f"+HEX={hex_path}", f"+NAME={name}"], capture_output=True, text=True).stdout
    lines = [l for l in out.splitlines() if re.match(r"(PASS|FAIL|TIMEOUT|BADADDR|ERROR)", l)]
    return lines[-1] if lines else f"ERROR   {name}: no result"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("hex", nargs="+")
    ap.add_argument("--sim", help="compiled testbench (build/sim_core); without it only the plan is printed")
    args = ap.parse_args()

    tests = {os.path.basename(h)[:-4]: (h, needed(h)) for h in args.hex}
    by_stage = [[] for _ in STAGES]
    for name, (h, names) in tests.items():
        by_stage[stage_of(names)].append(name)

    results = {name: run_core(args.sim, h) for name, (h, _) in tests.items()} if args.sim else {}
    total_pass = 0
    for i, (title, group) in enumerate(STAGES):
        names = sorted(by_stage[i])
        print(f"Stage {title}: implement {', '.join(group)}")
        if not names:
            print("  (no test needs exactly this stage)")
        for n in names:
            extra = sorted(tests[n][1] - set().union(*(set(g) for _, g in STAGES[:i])))
            if results:
                r = results[n]
                ok = r.startswith("PASS")
                total_pass += ok
                print(f"  {'ok  ' if ok else 'FAIL'} {n:7s} {'' if ok else r}")
            else:
                print(f"  {n:7s} uses {', '.join(extra) if extra else '(stage 1 only)'}")
        if results:
            done = sum(results[n].startswith("PASS") for n in names)
            print(f"  -> {done} / {len(names)} in this stage")
        print()
    if results:
        print(f"{total_pass} / {len(tests)} rv32ui tests pass")
        first = next((i for i, _ in enumerate(STAGES) if any(not results[n].startswith("PASS") for n in by_stage[i])), None)
        if first is not None:
            fails = [n for n in sorted(by_stage[first]) if not results[n].startswith("PASS")]
            print(f"Next: stage {STAGES[first][0]}, start with {fails[0]} (make trace T={fails[0]}; add RETIRE=1 once the retire_* ports exist)")
        sys.exit(0 if total_pass == len(tests) else 1)


if __name__ == "__main__":
    main()
