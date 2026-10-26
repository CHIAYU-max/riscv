#!/usr/bin/env python3
"""Compare the core's trace (tb_core.v +TRACE=...) with the golden model's (sw/iss.py --trace).

Stores (S lines) are always compared, in order; only the bytes enabled by strb count.
Retired instructions (R lines) are compared when the core's trace has any, that is
when the core has the optional retire ports and the testbench was built with RETIRE_TRACE.
The first mismatch is printed with the instructions before it and its disassembly.

usage: sw/trace_diff.py <reference trace> <core trace> [--dump build/tests/add.dump]
"""
import argparse
import re
import sys

CONTEXT = 5
PIPELINE_SLACK = 4


def parse(path):
    retire, stores = [], []
    with open(path) as f:
        for line in f:
            fields = dict(item.split("=") for item in line.split()[1:])
            if line.startswith("R "):
                retire.append({k: int(v, 16) if k != "rd" else int(v) for k, v in fields.items()})
            elif line.startswith("S "):
                stores.append({k: int(v, 16) for k, v in fields.items()})
    return retire, stores


def disassembly(dump_path):
    # objdump -d lines look like "     4c:	00208733          	add	a4,ra,sp"
    lines = {}
    if dump_path:
        with open(dump_path) as f:
            for line in f:
                m = re.match(r"\s*([0-9a-f]+):\s+[0-9a-f]{8}\s+(.*)", line)
                if m:
                    lines[int(m.group(1), 16)] = m.group(2).strip().replace("\t", " ")
    return lines


def fmt_retire(r, asm):
    write = f"x{r['rd']} <= 0x{r['val']:08x}" if r["rd"] else "(no register write)"
    return f"pc 0x{r['pc']:08x}  {r['insn']:08x}  {asm.get(r['pc'], ''):<28} {write}"


def store_bytes(s):
    mask = sum(0xFF << (8 * lane) for lane in range(4) if s["strb"] >> lane & 1)
    return s["addr"], s["strb"], s["data"] & mask


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("reference")
    parser.add_argument("core")
    parser.add_argument("--dump", help="objdump -d output, for disassembly in the report")
    args = parser.parse_args()
    ref_r, ref_s = parse(args.reference)
    dut_r, dut_s = parse(args.core)
    asm = disassembly(args.dump)
    ok = True

    if dut_r:
        for i, (want, got) in enumerate(zip(ref_r, dut_r)):
            if want != got:
                print(f"MISMATCH at retired instruction #{i}")
                for r in ref_r[max(0, i - CONTEXT):i]:
                    print(f"  ok        {fmt_retire(r, asm)}")
                print(f"  expected  {fmt_retire(want, asm)}")
                print(f"  core      {fmt_retire(got, asm)}")
                if want["pc"] != got["pc"]:
                    print("  -> wrong PC: check the branch / jump before this instruction, or a missed flush or stall")
                elif want["rd"] != got["rd"]:
                    print("  -> wrong destination: check rd decoding and the register write enable for this opcode")
                else:
                    print("  -> wrong value: check the ALU / immediate for this instruction, or forwarding from the instructions above")
                ok = False
                break
        else:
            # The TOHOST store ends the simulation while the instructions behind it are still in
            # the pipeline, so a core trace up to PIPELINE_SLACK instructions short is complete.
            if len(ref_r) - len(dut_r) > PIPELINE_SLACK:
                last = dut_r[-1] if dut_r else None
                print(f"MISMATCH core retired {len(dut_r)} instructions, golden model {len(ref_r)}")
                if last:
                    print(f"  last retired: {fmt_retire(last, asm)}")
                print(f"  next expected: {fmt_retire(ref_r[len(dut_r)], asm)}")
                ok = False
        if ok:
            print(f"retire: {len(dut_r)} instructions match")

    if ok:
        for i, (want, got) in enumerate(zip(ref_s, dut_s)):
            if store_bytes(want) != store_bytes(got):
                print(f"MISMATCH at store #{i}")
                print(f"  expected  addr 0x{want['addr']:08x} data 0x{want['data']:08x} strb {want['strb']:04b}")
                print(f"  core      addr 0x{got['addr']:08x} data 0x{got['data']:08x} strb {got['strb']:04b}")
                ok = False
                break
        else:
            if len(dut_s) != len(ref_s):
                print(f"MISMATCH core made {len(dut_s)} stores, golden model {len(ref_s)}")
                ok = False
        if ok:
            print(f"stores: {len(dut_s)} match")

    print("MATCH" if ok else "DIFFER")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
