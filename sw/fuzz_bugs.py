#!/usr/bin/env python3
"""Evaluate sw/fuzz.py the way TheHuzz and MABFuzz do: coverage over a fixed test budget on the correct
golden model, and tests-to-detection of bugs injected into copies of sw/iss.py (the reference is Spike).

The ten bugs are corner cases a single-cycle RV32I core can plausibly get wrong; B6 needs two dependent
instructions in a row (a load followed by a use of its result), the case the read-after-write bins target.
  B1  SRA by 31 shifts in zeros          B6  a load's result is not yet visible to the next instruction's rs1
  B2  SLTIU zero-extends its immediate   B7  SB to byte lane 3 writes lane 0
  B3  LH from lane 2 zero-extends        B8  SUB writes x0
  B4  BGE is not taken when equal        B9  AUIPC adds pc + 4
  B5  SLT is wrong when rs1 = INT_MIN    B10 SRLI by 0 returns 0
usage: sw/fuzz_bugs.py [--seeds 3] [--tests 1600] [--det-tests 800] [--policies random rr ucb exp3 ucb-dep] [--jobs 14]
Writes build/fuzz/eval/{coverage.csv,detect.csv,summary.md}.
"""
import argparse
import csv
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/fuzz/eval"
LL_USE = "        rs1, rs2, f7 = x[insn >> 15 & 31], x[insn >> 20 & 31], insn >> 25\n"
BUGS = {
    "B1": [("(5, 0x20): lambda: sext(rs1, 32) >> shamt,", "(5, 0x20): lambda: (sext(rs1, 32) >> shamt) if shamt != 31 else rs1 >> 31,")],
    "B2": [("value = int(rs1 < (imm_i & MASK))", "value = int(rs1 < (imm_i & 0xFFF))")],
    "B3": [("value = sext(word & 0xFFFF, 16)", "value = (word & 0xFFFF) if addr & 2 else sext(word & 0xFFFF, 16)")],
    "B4": [("5: s1 >= s2,", "5: s1 > s2,")],
    "B5": [("(2, 0): lambda: int(sext(rs1, 32) < sext(rs2, 32)),", "(2, 0): lambda: int(sext(rs1, 32) < sext(rs2, 32)) if rs1 != 0x80000000 else 0,")],
    "B6": [(LL_USE, LL_USE + "        if getattr(self, '_ll', None) and self._ll[0] == (insn >> 15 & 31):\n            rs1 = self._ll[1]\n"),
           ("            word = self.load_word(addr) >> (8 * (addr & 3))\n",
            "            word = self.load_word(addr) >> (8 * (addr & 3))\n            self._ll_next = (rd, x[rd]) if rd else None\n"),
           ("            self.store(addr, data & MASK, strb)\n", "            self._ll = None\n            self.store(addr, data & MASK, strb)\n"),
           ("        self.pc = next_pc & MASK\n", "        self._ll, self._ll_next = getattr(self, '_ll_next', None), None\n        self.pc = next_pc & MASK\n")],
    "B7": [("data, strb = (rs2 & 0xFF) << (8 * lane), 1 << lane", "data, strb = ((rs2 & 0xFF) << (8 * lane), 1 << lane) if lane != 3 else (rs2 & 0xFF, 1)")],
    "B8": [("if value is not None and rd != 0:", "if value is not None and (rd != 0 or (op == 0x33 and f7 == 0x20)):")],
    "B9": [("value = pc + imm_u", "value = pc + 4 + imm_u")],
    "B10": [("                value = rs1 >> shamt\n", "                value = rs1 >> shamt if shamt else 0\n")],
}


def make_mutants():
    src = (ROOT / "sw/iss.py").read_text()
    d = OUT / "bugs"
    d.mkdir(parents=True, exist_ok=True)
    paths = {}
    for name, edits in BUGS.items():
        text = src
        for old, new in edits:
            assert text.count(old) == 1, (name, old)
            text = text.replace(old, new)
        p = d / f"iss_{name}.py"
        p.write_text(text)
        paths[name] = p
    return paths


def fuzz(policy, seed, tests, jobs, out, iss=None, stop=False):
    cmd = [sys.executable, str(ROOT / "sw/fuzz.py"), "--policy", policy, "--seed", str(seed), "--tests", str(tests),
           "--jobs", str(jobs), "--out", str(out)] + (["--iss", str(iss)] if iss else []) + (["--stop"] if stop else [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode not in (0, 1):
        sys.exit(r.stderr)
    return r.stdout.strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--tests", type=int, default=1600)
    ap.add_argument("--policies", nargs="+", default=["random", "rr", "ucb", "exp3", "ucb-dep"])
    ap.add_argument("--jobs", type=int, default=14)
    ap.add_argument("--det-tests", type=int, default=800, help="budget per detection run")
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    mutants = make_mutants()
    cov_rows, det_rows = [], []
    for p in a.policies:
        for s in range(1, a.seeds + 1):
            d = OUT / f"cov_{p}_{s}"
            print(fuzz(p, s, a.tests, a.jobs, d), flush=True)
            curve = list(csv.reader(open(d / "curve.csv")))[1:]
            fails = len(list(d.glob("fail_*.S")))
            for tests, bins in curve:
                cov_rows.append({"policy": p, "seed": s, "tests": int(tests), "bins": int(bins)})
            assert fails == 0, f"the correct golden model mismatched Spike in {d}"
            for bug, path in mutants.items():
                bd = OUT / f"det_{p}_{s}_{bug}"
                fuzz(p, s, a.det_tests, a.jobs, bd, iss=path, stop=True)
                first = (bd / "first_fail.txt").read_text().strip()
                det_rows.append({"policy": p, "seed": s, "bug": bug, "tests": int(first) if first != "none" else None})
                print(f"  {p} {s} {bug}: {first}", flush=True)
    with open(OUT / "coverage.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(cov_rows[0]))
        w.writeheader()
        w.writerows(cov_rows)
    with open(OUT / "detect.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(det_rows[0]))
        w.writeheader()
        w.writerows(det_rows)

    def final(p, s):
        return max(r["bins"] for r in cov_rows if r["policy"] == p and r["seed"] == s)

    def reach(p, s, target):
        return next((r["tests"] for r in cov_rows if r["policy"] == p and r["seed"] == s and r["bins"] >= target), None)

    lines = ["# sw/fuzz.py evaluation", "", f"{a.seeds} seeds x {a.tests} tests per policy; golden model vs Spike; "
             f"detection = index of the first mismatching test within {a.det_tests} tests (batch granularity = --jobs).", "",
             "## Functional coverage (bins) after the full budget", "", "| policy | mean bins | per seed | tests to reach random's mean final |",
             "| --- | ---: | --- | --- |"]
    rnd = statistics.mean(final("random", s) for s in range(1, a.seeds + 1)) if "random" in a.policies else None
    for p in a.policies:
        fs = [final(p, s) for s in range(1, a.seeds + 1)]
        rs = [reach(p, s, rnd) for s in range(1, a.seeds + 1)] if rnd else []
        lines.append(f"| {p} | {statistics.mean(fs):.1f} | {' / '.join(map(str, fs))} | {' / '.join(str(x) if x else '-' for x in rs)} |")
    lines += ["", "## Tests to detection (median over seeds; '-' = not found within the budget)", "",
              "| bug | " + " | ".join(a.policies) + " |", "| --- |" + " ---: |" * len(a.policies)]
    for bug in BUGS:
        cells = []
        for p in a.policies:
            v = [r["tests"] for r in det_rows if r["policy"] == p and r["bug"] == bug]
            found = [x for x in v if x is not None]
            cells.append(f"{statistics.median(found):.0f} ({len(found)}/{len(v)})" if found else f"- (0/{len(v)})")
        lines.append(f"| {bug} | " + " | ".join(cells) + " |")
    (OUT / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
