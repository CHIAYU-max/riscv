#!/usr/bin/env python3
"""Coverage-guided differential instruction fuzzer for the RV32I golden model and, later, the core.

Borrowed from Texas A&M's SETH lab (docs/design-notes.md, "Ideas taken from TheHuzz and MABFuzz"):
  - TheHuzz (USENIX Security 2022): a test = configuration instructions (CIs, never mutated) + 20 test
    instructions (TIs) mutated as binary words with the twelve AFL-style operators of its Table 4
    (M0-M7 data bits only; M8 random byte, M9 delete, M10 clone, M11 opcode); a mutant is kept only if it
    reaches new coverage; any mismatch with the golden reference model is a bug.
  - MABFuzz (DATE 2024): seed selection as a multi-armed bandit. Arms = 10 seeds; reward
    alpha * |new to this arm| + (1 - alpha) * |new to all arms|, alpha = 0.25; UCB1 or EXP3 (eta = 0.1);
    an arm with no coverage increase in its last gamma = 3 pulls is replaced by a fresh seed.
Changes for this core, which has no traps, CSRs or ECALL (CLAUDE.md): every mutant is repaired into a
legal, terminating RV32I instruction (illegal opcodes and SYSTEM are mapped to legal ones, loads and stores
use t6 with an aligned offset inside the data buffer, branches and JAL jump forward inside the test, rd is
never t5 / t6; JALR is left to sw/gen_random.py). So the illegal-instruction bugs TheHuzz finds with M11
are out of scope here; M11 still changes the instruction type.

Coverage is ISA-level functional coverage computed from the golden model's trace, so it does not need the
core: bins for each mnemonic x rd == x0, operand value classes (0, 1, -1, INT_MIN, INT_MAX, other +/-),
immediate classes, rs1 == rs2, result class, branch taken / not taken, load / store byte lane, and
read-after-write pairs between consecutive instructions (prev class x next class x operand), which a
pipelined core needs. RTL coverage (Verilator --coverage) is the next step once the core passes rv32ui.

Check: --ref spike   the golden model (sw/iss.py) against Spike, every retired instruction and store
       --ref core    the core (vvp image, --sim) against the golden model (needs the core)
Policies: random (a fresh random test each time: random regression), rr (TheHuzz-style mutation, arms in
round robin), ucb, exp3 (MABFuzz), ucb-dep (ucb plus our M12 dependency operator). Same test budget for each.

usage: sw/fuzz.py --policy ucb --tests 1600 --seed 1 [--ref spike|core --sim build/sim_core_retire]
                  [--jobs 14] [--out build/fuzz/ucb_1]
Writes <out>/curve.csv (tests run, bins covered), <out>/bins.txt, and keeps every mismatching test as
<out>/fail_<n>.{S,diff}. Exits non-zero if any test mismatched.
"""
import argparse
import csv
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

N_TI = 20
DATA_WORDS = 64                        # 256-byte buffer, t6 at its middle (as in sw/gen_random.py)
NOP = 0x00000013
FENCE = 0x0FF0000F
EDGE32 = [0, 1, 2, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0x80000001, 0xFFFFFFFE, 0x0000FFFF, 0xFFFF0000,
          0x000000FF, 0x00000080, 0x0000007F, 0x00008000]
EDGE12 = [0, 1, -1, 2047, -2048, 2046, -2047, 0x7F, 0x80, -0x80]
OPC = {"op": 0x33, "opimm": 0x13, "lui": 0x37, "auipc": 0x17, "load": 0x03, "store": 0x23,
       "branch": 0x63, "jal": 0x6F, "fence": 0x0F}
LEGAL_OPC = list(OPC.values())
LOAD_F3 = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}          # lb lh lw lbu lhu -> size
STORE_F3 = {0: 1, 1: 2, 2: 4}
BRANCH_F3 = [0, 1, 4, 5, 6, 7]
ROOT = Path(__file__).resolve().parent.parent
PREFIX = os.environ.get("RISCV_PREFIX", "riscv64-unknown-elf-")


# ---------- encoding ----------
def bits(v, hi, lo):
    return (v >> lo) & ((1 << (hi - lo + 1)) - 1)


def sext(v, n):
    v &= (1 << n) - 1
    return v - (1 << n) if v >> (n - 1) else v


def enc_i(op, rd, f3, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def enc_s(op, f3, rs1, rs2, imm):
    imm &= 0xFFF
    return (bits(imm, 11, 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (bits(imm, 4, 0) << 7) | op


def enc_b(f3, rs1, rs2, off):
    off &= 0x1FFF
    return (bits(off, 12, 12) << 31) | (bits(off, 10, 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
        | (bits(off, 4, 1) << 8) | (bits(off, 11, 11) << 7) | 0x63


def enc_j(rd, off):
    off &= 0x1FFFFF
    return (bits(off, 20, 20) << 31) | (bits(off, 10, 1) << 21) | (bits(off, 11, 11) << 20) \
        | (bits(off, 19, 12) << 12) | (rd << 7) | 0x6F


def imm_i(w):
    return sext(w >> 20, 12)


def imm_s(w):
    return sext((bits(w, 31, 25) << 5) | bits(w, 11, 7), 12)


def imm_b(w):
    return sext((bits(w, 31, 31) << 12) | (bits(w, 7, 7) << 11) | (bits(w, 30, 25) << 5) | (bits(w, 11, 8) << 1), 13)


def imm_j(w):
    return sext((bits(w, 31, 31) << 20) | (bits(w, 19, 12) << 12) | (bits(w, 20, 20) << 11) | (bits(w, 30, 21) << 1), 21)


def safe_rd(rd):
    return rd - 2 if rd in (30, 31) else rd


def repair(w, slot):
    """Map any 32-bit word to a legal RV32I instruction that is safe in TI slot `slot` of N_TI."""
    op = w & 0x7F
    if op not in LEGAL_OPC:
        op = LEGAL_OPC[(w >> 2) % len(LEGAL_OPC)]
        w = (w & ~0x7F) | op
    rd, f3, rs1, rs2, f7 = bits(w, 11, 7), bits(w, 14, 12), bits(w, 19, 15), bits(w, 24, 20), bits(w, 31, 25)
    span = N_TI - slot                                    # forward targets: 1..span instructions ahead
    if op == OPC["op"]:
        f7 = 0x20 if (f7 & 0x20 and f3 in (0, 5)) else 0
        return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (safe_rd(rd) << 7) | op
    if op == OPC["opimm"]:
        imm = imm_i(w)
        if f3 == 1:
            imm &= 0x1F
        elif f3 == 5:
            imm = (imm & 0x1F) | (0x400 if imm & 0x400 else 0)
        return enc_i(op, safe_rd(rd), f3, rs1, imm)
    if op in (OPC["lui"], OPC["auipc"]):
        return (w & 0xFFFFF000) | (safe_rd(rd) << 7) | op
    if op == OPC["load"]:
        f3 = f3 if f3 in LOAD_F3 else (0, 1, 2, 4, 5)[f3 % 5]
        size = LOAD_F3[f3]
        off = (imm_i(w) % (DATA_WORDS * 4)) - DATA_WORDS * 2
        return enc_i(op, safe_rd(rd), f3, 31, off - off % size)
    if op == OPC["store"]:
        f3 = f3 if f3 in STORE_F3 else f3 % 3
        size = STORE_F3[f3]
        off = (imm_s(w) % (DATA_WORDS * 4)) - DATA_WORDS * 2
        return enc_s(op, f3, 31, rs2, off - off % size)
    if op == OPC["branch"]:
        f3 = f3 if f3 in BRANCH_F3 else BRANCH_F3[f3 % 6]
        return enc_b(f3, rs1, rs2, 4 * (1 + (abs(imm_b(w)) // 4) % span))
    if op == OPC["jal"]:
        return enc_j(safe_rd(rd), 4 * (1 + (abs(imm_j(w)) // 4) % span))
    return FENCE


# ---------- tests ----------
def rand_word(rng):
    return rng.choice(EDGE32) if rng.random() < 0.3 else rng.getrandbits(32)


def rand_ti(rng, slot):
    kind = rng.choice(["op"] * 6 + ["opimm"] * 5 + ["lui", "auipc"] + ["load"] * 3 + ["store"] * 3
                      + ["branch"] * 3 + ["jal", "fence"])
    reg = lambda: rng.randrange(32)
    imm = lambda: rng.choice(EDGE12) if rng.random() < 0.3 else rng.randint(-2048, 2047)
    rd = 0 if rng.random() < 0.05 else rng.randrange(1, 30)
    if kind == "op":
        w = (rng.choice([0, 0x20]) << 25) | (reg() << 20) | (reg() << 15) | (rng.randrange(8) << 12) | (rd << 7) | 0x33
    elif kind == "opimm":
        w = enc_i(0x13, rd, rng.randrange(8), reg(), imm())
    elif kind in ("lui", "auipc"):
        w = (rng.getrandbits(20) << 12) | (rd << 7) | OPC[kind]
    elif kind == "load":
        w = enc_i(0x03, rd, rng.choice(list(LOAD_F3)), 31, rng.getrandbits(12))
    elif kind == "store":
        w = enc_s(0x23, rng.choice(list(STORE_F3)), 31, reg(), rng.getrandbits(12))
    elif kind == "branch":
        a = reg()
        w = enc_b(rng.choice(BRANCH_F3), a, a if rng.random() < 0.15 else reg(), 4 * rng.randint(1, 4))
    elif kind == "jal":
        w = enc_j(rd, 4 * rng.randint(1, 4))
    else:
        w = FENCE
    return repair(w, slot)


def rand_test(rng):
    return {"regs": [rand_word(rng) for _ in range(30)], "data": [rand_word(rng) for _ in range(DATA_WORDS)],
            "ti": [rand_ti(rng, i) for i in range(N_TI)]}


def mutate(test, rng, dep=False):
    """TheHuzz Table 4 operators (M0-M11) on 1-3 TIs, then repair. dep adds M12 (ours, not in TheHuzz):
    make the next TI read this TI's rd as rs1 or rs2, a read-after-write pair such as load-use."""
    t = {"regs": test["regs"], "data": test["data"], "ti": list(test["ti"])}
    for _ in range(rng.randint(1, 3)):
        i = rng.randrange(N_TI)
        w = t["ti"][i]
        m = rng.randrange(13 if dep else 12)
        if m == 12:
            if i == N_TI - 1:
                i -= 1
            rd = bits(t["ti"][i], 11, 7) or rng.randrange(1, 30)
            nxt = t["ti"][i + 1]
            shift = rng.choice((15, 20))
            t["ti"][i + 1] = repair((nxt & ~(31 << shift)) | (rd << shift), i + 1)
            continue
        data_bits = [b for b in range(7, 32)]                    # M0-M7 leave the opcode [6:0] alone
        if m <= 2:
            n = (1, 2, 4)[m]
            b = rng.choice(data_bits[: len(data_bits) - n + 1])
            w ^= ((1 << n) - 1) << b
        elif m in (3, 4):
            n = 8 * (m - 2)
            b = rng.choice([8, 16, 24][: 4 - n // 8])
            w ^= ((1 << n) - 1) << b
        elif m in (5, 6, 7):
            n = (8, 16, 32)[m - 5]
            b = 0 if n == 32 else rng.choice([8, 16, 24][: 4 - n // 8])
            mask = ((1 << n) - 1) << b
            v = ((w & mask) >> b) + rng.choice((-1, 1)) * rng.randint(0, 35)
            w = (w & ~mask) | ((v << b) & mask)
            w = (w & ~0x7F) | (t["ti"][i] & 0x7F)
        elif m == 8:
            b = 8 * rng.randrange(4)
            w = (w & ~(0xFF << b)) | (rng.getrandbits(8) << b)
        elif m == 9:
            w = NOP
        elif m == 10:
            w = t["ti"][rng.randrange(N_TI)]
        else:
            w = (w & ~0x7F) | rng.getrandbits(7)
        t["ti"][i] = repair(w & 0xFFFFFFFF, i)
    return t


def render(test):
    out = ['#include "riscv_test.h"', "RVTEST_RV32U", "RVTEST_CODE_BEGIN", f"  la t6, fz_data + {DATA_WORDS * 2}"]
    out += [f"  li x{r + 1}, 0x{v:08x}" for r, v in enumerate(test["regs"][:29])]
    out += ["  li x30, 0", "fz_body:"] + [f"  .word 0x{w:08x}" for w in test["ti"]]
    out += ["fz_end:", "  RVTEST_PASS", "RVTEST_CODE_END", "", "  .data", "RVTEST_DATA_BEGIN", "  .align 4", "fz_data:"]
    out += [f"  .word 0x{v:08x}" for v in test["data"]] + ["RVTEST_DATA_END", ""]
    return "\n".join(out)


# ---------- run + coverage ----------
def run_test(args):
    test, ref, sim, iss_path = args
    with tempfile.TemporaryDirectory(prefix="fz_") as d:
        b = Path(d) / "t"
        Path(f"{b}.S").write_text(render(test))
        cc = subprocess.run([f"{PREFIX}gcc", "-march=rv32i", "-mabi=ilp32", "-static", "-nostdlib", "-nostartfiles",
                             "-T", str(ROOT / "sw/env/link.ld"), "-Wl,--no-warn-rwx-segments", f"-I{ROOT / 'sw/env'}",
                             f"{b}.S", "-o", f"{b}.elf"], capture_output=True, text=True)
        if cc.returncode:
            return {"error": "build: " + cc.stderr[-300:]}
        subprocess.run([f"{PREFIX}objcopy", "-O", "binary", f"{b}.elf", f"{b}.bin"], check=True)
        subprocess.run([sys.executable, str(ROOT / "sw/bin2hex.py"), f"{b}.bin", f"{b}.hex"], check=True)
        subprocess.run([f"{PREFIX}objdump", "-d", f"{b}.elf"], stdout=open(f"{b}.dump", "w"), check=True)
        iss = subprocess.run([sys.executable, iss_path, "--max-steps", "5000", f"{b}.hex",
                              "--trace", f"{b}.ref"], capture_output=True, text=True)
        status = iss.stdout.strip().splitlines()[-1] if iss.stdout.strip() else "?"
        ref_lines = Path(f"{b}.ref").read_text().splitlines()
        steps = sum(1 for l in ref_lines if l.startswith("R "))
        if ref == "spike":
            subprocess.run([sys.executable, str(ROOT / "sw/spike_trace.py"), f"{b}.elf", "--trace", f"{b}.other",
                            "--max-steps", str(steps)], capture_output=True, text=True)
        else:
            subprocess.run(["vvp", "-n", sim, f"+HEX={b}.hex", "+NAME=fz", f"+TRACE={b}.other"], capture_output=True, text=True)
        diff = subprocess.run([sys.executable, str(ROOT / "sw/trace_diff.py"), f"{b}.ref", f"{b}.other", "--dump", f"{b}.dump"],
                              capture_output=True, text=True)
        res = {"bins": coverage(ref_lines, symbol(f"{b}.dump", "fz_body"), symbol(f"{b}.dump", "fz_end")), "pass": "PASS" in status, "status": status,
               "mismatch": diff.returncode != 0}
        if res["mismatch"] or not res["pass"]:
            res["S"], res["diff"] = Path(f"{b}.S").read_text(), diff.stdout[-4000:]
        return res


MNEM = {(0x33, 0, 0): "add", (0x33, 0, 0x20): "sub", (0x33, 1, 0): "sll", (0x33, 2, 0): "slt", (0x33, 3, 0): "sltu",
        (0x33, 4, 0): "xor", (0x33, 5, 0): "srl", (0x33, 5, 0x20): "sra", (0x33, 6, 0): "or", (0x33, 7, 0): "and"}
OPIMM = ["addi", "slli", "slti", "sltiu", "xori", "srxi", "ori", "andi"]
LOADN = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}
STOREN = {0: "sb", 1: "sh", 2: "sw"}
BRN = {0: "beq", 1: "bne", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}


def vclass(v):
    v &= 0xFFFFFFFF
    return {0: "0", 1: "1", 0xFFFFFFFF: "-1", 0x80000000: "min", 0x7FFFFFFF: "max"}.get(v, "neg" if v >> 31 else "pos")


def iclass(i):
    return {0: "0", 1: "1", -1: "-1", 2047: "max", -2048: "min"}.get(i, "neg" if i < 0 else "pos")


def decode(w):
    op, f3, f7 = w & 0x7F, bits(w, 14, 12), bits(w, 31, 25)
    if op == 0x33:
        return MNEM.get((op, f3, f7), "op?"), "alu", True, True
    if op == 0x13:
        n = OPIMM[f3] if f3 != 5 else ("srai" if f7 & 0x20 else "srli")
        return n, "alu", True, False
    if op in (0x37, 0x17):
        return ("lui" if op == 0x37 else "auipc"), "upper", False, False
    if op == 0x03:
        return LOADN.get(f3, "ld?"), "load", True, False
    if op == 0x23:
        return STOREN.get(f3, "st?"), "store", True, True
    if op == 0x63:
        return BRN.get(f3, "br?"), "branch", True, True
    if op == 0x6F:
        return "jal", "jump", False, False
    if op == 0x67:
        return "jalr", "jump", True, False
    return "fence" if op == 0x0F else f"op{op:02x}", "other", False, False


def coverage(ref_lines, lo, hi):
    """Bins hit by the retired instructions with lo <= pc < hi (the TIs); registers replayed from the trace."""
    regs = [0] * 32
    retired = [dict(x.split("=") for x in l.split()[1:]) for l in ref_lines if l.startswith("R ")]
    bins, prev = set(), None
    for k, r in enumerate(retired):
        pc, w, rd, val = int(r["pc"], 16), int(r["insn"], 16), int(r["rd"]), int(r["val"], 16)
        if not lo <= pc < hi:
            if rd:
                regs[rd] = val
            prev = None
            continue
        name, cls, use1, use2 = decode(w)
        rs1, rs2 = bits(w, 19, 15), bits(w, 24, 20)
        a, b = regs[rs1], regs[rs2]
        bins.add(("rd0", name, bits(w, 11, 7) == 0))
        if use1:
            bins.add(("rs1", name, vclass(a)))
        if use2:
            bins.add(("rs2", name, vclass(b)))
            bins.add(("ab", name, vclass(a), vclass(b)))
            bins.add(("same", name, rs1 == rs2))
        if cls == "alu" and not use2:
            bins.add(("imm", name, iclass(imm_i(w))))
        if cls in ("alu", "upper", "load") and rd:
            bins.add(("res", name, vclass(val)))
        if cls == "branch" and k + 1 < len(retired):
            bins.add(("taken", name, int(retired[k + 1]["pc"], 16) != pc + 4))
        if cls == "load":
            bins.add(("lane", name, (a + imm_i(w)) & 3))
        if cls == "store":
            bins.add(("lane", name, (a + imm_s(w)) & 3))
        if prev and prev[1] != 0:
            if use1 and prev[1] == rs1:
                bins.add(("raw", prev[0], cls, "rs1"))
            if use2 and prev[1] == rs2:
                bins.add(("raw", prev[0], cls, "rs2"))
        prev = (cls, bits(w, 11, 7) if cls not in ("store", "branch") else 0)
        if rd:
            regs[rd] = val
    return bins


def symbol(dump, name):
    for line in Path(dump).read_text().splitlines():
        if line.endswith(f"<{name}>:"):
            return int(line.split()[0], 16)
    raise ValueError(f"no symbol {name}")


# ---------- policies ----------
class Arm:
    def __init__(self, test):
        self.test, self.cov, self.n, self.q, self.w, self.hist = test, set(), 0, 0.0, 1.0, []


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--policy", choices=["random", "rr", "ucb", "exp3", "ucb-dep"], default="ucb")
    ap.add_argument("--tests", type=int, default=1600)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--ref", choices=["spike", "core"], default="spike")
    ap.add_argument("--sim", default="build/sim_core_retire")
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 2))
    ap.add_argument("--out", default=None)
    ap.add_argument("--arms", type=int, default=10)
    ap.add_argument("--alpha", type=float, default=0.25)
    ap.add_argument("--gamma", type=int, default=3)
    ap.add_argument("--eta", type=float, default=0.1)
    ap.add_argument("--iss", default=str(ROOT / "sw/iss.py"), help="golden model to run (a copy with an injected bug for sw/fuzz_bugs.py)")
    ap.add_argument("--stop", action="store_true", help="stop at the first mismatching test (tests-to-detection)")
    a = ap.parse_args()
    out = Path(a.out or f"build/fuzz/{a.policy}_{a.seed}")
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    rng = random.Random(a.seed)
    seen, curve, fails, done, t = set(), [], 0, 0, 0
    arms = [Arm(rand_test(rng)) for _ in range(a.arms)]
    pool = ProcessPoolExecutor(a.jobs)

    def run(batch):
        nonlocal fails, done
        results = list(pool.map(run_test, [(x, a.ref, a.sim, a.iss) for x in batch]))
        for x, r in zip(batch, results):
            done += 1
            if "error" in r:
                sys.exit(f"fuzz: {r['error']}")
            if r["mismatch"] or not r["pass"]:
                fails += 1
                (out / f"fail_{done}.S").write_text(r["S"])
                (out / f"fail_{done}.diff").write_text(f"status {r['status']}\n" + r["diff"])
        return results

    while done < a.tests and not (a.stop and fails):
        if a.policy == "random":
            batch = [rand_test(rng) for _ in range(min(a.jobs, a.tests - done))]
            for r in run(batch):
                seen |= r["bins"]
            curve.append((done, len(seen)))
            continue
        t += 1
        if a.policy == "rr":
            k = (t - 1) % len(arms)
        elif a.policy in ("ucb", "ucb-dep"):
            untried = [i for i, arm in enumerate(arms) if arm.n == 0]
            k = untried[0] if untried else max(range(len(arms)), key=lambda i: arms[i].q + math.sqrt(2 * math.log(t) / arms[i].n))
        else:
            tot = sum(arm.w for arm in arms)
            p = [(1 - a.eta) * arm.w / tot + a.eta / len(arms) for arm in arms]
            k = rng.choices(range(len(arms)), weights=p)[0]
        arm = arms[k]
        batch = [arm.test] if arm.n == 0 and not arm.cov else []
        batch += [mutate(arm.test, rng, a.policy == "ucb-dep") for _ in range(min(a.jobs, a.tests - done) - len(batch))]
        results = run(batch)
        local, glob = set(), set()
        best, best_gain = None, 0
        for x, r in zip(batch, results):
            new_local = r["bins"] - arm.cov - local
            new_glob = r["bins"] - seen - glob
            local |= new_local
            glob |= new_glob
            if len(new_glob) > best_gain:
                best, best_gain = x, len(new_glob)
        arm.cov |= local
        seen |= glob
        if best is not None:
            arm.test = best                        # keep the mutant that reached new coverage (TheHuzz)
        reward = a.alpha * len(local) + (1 - a.alpha) * len(glob)
        arm.n += 1
        arm.q += (reward - arm.q) / arm.n
        if a.policy == "exp3":
            pk = (1 - a.eta) * arm.w / sum(x.w for x in arms) + a.eta / len(arms)
            arm.w *= math.exp(a.eta * (reward / max(1, len(seen))) / pk / len(arms))
        arm.hist.append(len(local))
        if a.policy != "rr" and len(arm.hist) >= a.gamma and sum(arm.hist[-a.gamma:]) == 0:   # saturated arm -> new seed
            new = Arm(rand_test(rng))
            if a.policy == "exp3":
                others = [x.w for i, x in enumerate(arms) if i != k]
                new.w = sum(others) / len(others)
            arms[k] = new
        curve.append((done, len(seen)))
    pool.shutdown()
    with open(out / "curve.csv", "w", newline="") as f:
        csv.writer(f).writerows([("tests", "bins")] + curve)
    (out / "bins.txt").write_text("\n".join(sorted(map(str, seen))) + "\n")
    (out / "first_fail.txt").write_text(str(first) if (first := min([int(p.stem.split("_")[1]) for p in out.glob("fail_*.S")], default=0)) else "none")
    print(f"{a.policy} seed {a.seed}: {done} tests, {len(seen)} bins, {fails} mismatching or failing tests -> {out}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
