#!/usr/bin/env python3
"""Run a program on Spike (the reference RISC-V ISA simulator) and write its trace in the format of
sw/iss.py --trace, so that sw/trace_diff.py can compare the golden model with an independent one.

Spike runs the ELF with RAM at 0 (64 KiB, as in tb_core.v and sw/iss.py) and an I/O region at
0x8000_0000 (TOHOST, LED, SEG, the register block). Its commit log (--log-commits) becomes
  R pc=<pc> insn=<insn> rd=<rd> val=<value>   (rd=00 val=00000000 when nothing is written, x0 included)
  S addr=<addr> data=<data> strb=<strb>       (data in its byte lanes, as in sw/iss.py)
and the trace ends at the store to TOHOST, as the golden model's does.

Spike needs two local changes (docs/spike.md): its reset vector moved from 0x1000 to 0x2000_0000,
because the boot ROM would overlap RAM at 0, and dtc on PATH. Spike's boot ROM leaves a0..a2 and t0
nonzero when the program starts; the rv32ui tests and the random programs clear all registers first,
and crt0 does not read them. Only base RV32I is decoded (--isa=rv32i): programs with the custom
instructions (dot4, max4, requant, ...) stop as ILLEGAL. The commit log does not record traps; a trap
sends Spike to mtvec, which is 0 after reset, and no program jumps back to _start, so an instruction
at pc 0 after the first one is reported as ILLEGAL at the instruction after the last one retired.

usage: sw/spike_trace.py build/tests/add.elf --trace build/spike/add.spike [--max-steps n]
environment: SPIKE (default ~/tools/spike/bin/spike), SPIKE_DTC (directory of dtc, default
             ~/tools/dtc/usr/bin; its libfdt is found next to it in ../lib/x86_64-linux-gnu)
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

TOHOST = 0x8000_0000
MEMORY = "-m0x0:0x10000,0x80000000:0x10000"
HOME = Path.home()
COMMIT = re.compile(r"core\s+\d+: \d+ 0x([0-9a-f]+) \(0x([0-9a-f]+)\)(.*)")


def run_spike(elf, max_steps):
    spike = os.environ.get("SPIKE", str(HOME / "tools/spike/bin/spike"))
    dtc = Path(os.environ.get("SPIKE_DTC", str(HOME / "tools/dtc/usr/bin")))
    env = dict(os.environ)
    env["PATH"] = f"{dtc}:{env.get('PATH', '')}"
    env["LD_LIBRARY_PATH"] = f"{dtc.parent / 'lib/x86_64-linux-gnu'}:{env.get('LD_LIBRARY_PATH', '')}"
    with tempfile.NamedTemporaryFile(suffix=".log") as log:
        cmd = [spike, "--no-dm", "--disable-dtb", "--isa=rv32i", MEMORY, "--pc=0", "--log-commits",
               f"--log={log.name}", f"--instructions={max_steps}", str(elf)]
        done = subprocess.run(cmd, env=env, capture_output=True, text=True)
        out = Path(log.name).read_text()
    if "overlap" in done.stderr:
        sys.exit("spike: boot ROM overlaps RAM at 0; rebuild Spike with DEFAULT_RSTVEC 0x20000000 (docs/spike.md)")
    if done.returncode not in (0, 255) and not out:
        sys.exit(f"spike failed ({done.returncode}): {done.stderr.strip()}")
    return out


def store_line(addr, value, digits):
    lane = addr & 3
    if digits == 2:
        data, strb = value << (8 * lane), 1 << lane
    elif digits == 4:
        data, strb = value << (8 * (lane & 2)), 3 << (lane & 2)
    else:
        data, strb = value, 0xF
    return f"S addr={addr:08x} data={data & 0xFFFFFFFF:08x} strb={strb:x}"


def convert(log):
    """Commit log -> (trace lines, status, retired instructions)."""
    trace, retired, last = [], 0, None
    for line in log.splitlines():
        m = COMMIT.match(line)
        if not m:
            continue
        pc, insn, rest = int(m.group(1), 16), int(m.group(2), 16), m.group(3)
        if pc == 0 and retired:
            return trace, f"ILLEGAL (trap after pc 0x{last:08x})", retired
        last = pc
        rd, val, store = 0, 0, None
        w = re.search(r"\bx(\d+)\s+0x([0-9a-f]+)", rest)
        if w and int(w.group(1)) != 0:
            rd, val = int(w.group(1)), int(w.group(2), 16)
        s = re.search(r"\bmem 0x([0-9a-f]+) 0x([0-9a-f]+)\s*$", rest)
        if s and insn & 0x7F == 0x23:
            store = (int(s.group(1), 16), int(s.group(2), 16), len(s.group(2)))
        trace.append(f"R pc={pc:08x} insn={insn:08x} rd={rd:02d} val={val:08x}")
        retired += 1
        if store:
            trace.append(store_line(*store))
            if store[0] == TOHOST:
                data = store[1]
                return trace, "PASS" if data == 1 else f"FAIL ({data >> 1})", retired
    return trace, "TIMEOUT", retired


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("elf")
    parser.add_argument("--trace", help="write the trace to this file")
    parser.add_argument("--max-steps", type=int, default=1_000_000)
    args = parser.parse_args()
    trace, status, retired = convert(run_spike(args.elf, args.max_steps + 16))
    if args.trace:
        Path(args.trace).parent.mkdir(parents=True, exist_ok=True)
        Path(args.trace).write_text("".join(line + "\n" for line in trace))
    print(f"{status:<7} {Path(args.elf).stem} on spike ({retired} instructions)")
    sys.exit(0 if status == "PASS" else 1)


if __name__ == "__main__":
    main()
