#!/usr/bin/env python3
"""Pick tile sizes for running one whole U-Net layer as block-benchmark tiles in the core's data memory.

After MAFAT (Farley and Gerstlauer, IESS 2022; docs/design-notes.md, "Ideas taken from UT Austin work", item 4):
predict each tile's memory from its shape, keep the tiles that fit, and only then build and run. The predictor is
the memory sw/c/bench/block.c allocates for one tile (input tile with its 1-pixel halo, weights, bias, requant
parameters, the INT32 accumulators, the requantized map, the pooled map and the expected output), plus a fixed part
(code, stack, the rest of .data / .bss) that --calibrate measures from real builds, the way MAFAT fits a constant bias.

The whole layer is covered by tiles of OH x OW output pixels (even, for the 2 x 2 pooling) and COUT output channels
(a multiple of 4); every tile re-reads its halo, so the input bytes per output pixel grow as tiles shrink. Tiles are
ranked by the bytes moved between the host and the board for the whole layer (the halo and the weights are sent again
for every tile). Predicted instructions are printed too: per-tile instructions = a * outputs + b * pixels + c
(outputs = pixels x COUT; with CIN fixed, MACs are 9 x CIN x outputs), with a, b, c fitted by --calibrate from
golden-model runs of block_rb (sw/iss.py). On block_rb they depend almost only on the number of outputs, so the tile
shape changes the data moved, not the compute.

usage:
  sw/tile_plan.py --calibrate                       # build and run a few shapes, write build/tile_plan_cal.json
  sw/tile_plan.py [--mem-kib 32] [--h 512 --w 512 --cin 32 --cout 32] [--top 8]
  sw/tile_plan.py --check OH OW COUT                # build that shape and confirm it links and passes
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CAL = ROOT / "build" / "tile_plan_cal.json"
PROGRAM = "block_rb"            # register-blocked convolution with dot4 / requant / max4 (the fastest RV32I build)
CAL_SHAPES = [(4, 4, 8), (4, 8, 8), (8, 8, 8), (4, 4, 16), (8, 4, 16), (8, 8, 4)]


def tile_bytes(oh, ow, cin, cout):
    """Bytes block.c allocates for one tile (arrays in block_data.h and the static buffers in block.c)."""
    act = (oh + 2) * (ow + 2) * cin
    wgt = cout * 9 * cin
    small = 4 * cout + 4 * cout                     # bias, rq_params
    acc = 4 * oh * ow * cout
    act_out = oh * ow * cout
    pooled = (oh // 2) * (ow // 2) * cout
    expected = pooled
    pad = 4 * 7                                     # up to 3 bytes of alignment per array
    return act + wgt + small + acc + act_out + pooled + expected + pad


def run(cmd):
    return subprocess.run(cmd, cwd=ROOT, check=True, capture_output=True, text=True).stdout


def build(oh, ow, cout, cin):
    shape = f"--cin {cin} --oh {oh} --ow {ow} --cout {cout}"
    run(["make", "-s", f"build/c/{PROGRAM}.hex", f"BLOCK_SHAPE={shape}"])
    sizes = run(["riscv64-unknown-elf-size", "-A", f"build/c/{PROGRAM}.elf"])
    total = sum(int(m.group(1)) for m in re.finditer(r"^\.(?:text|data|rodata|bss|sdata|sbss|srodata)\S*\s+(\d+)", sizes, re.M))
    out = run(["python3", "sw/iss.py", "--dot4", "--max-steps", "50000000", f"build/c/{PROGRAM}.hex"])
    m = re.search(r"PASS\s+\S+ \((\d+) instructions\)", out)
    if not m:
        raise SystemExit(f"{PROGRAM} {oh}x{ow}x{cout}: {out.strip()}")
    return total, int(m.group(1))


def fit(rows):
    """Least squares for instr = a * outputs + b * pixels + c (three unknowns, no numpy needed)."""
    xs = [(r["outputs"], r["oh"] * r["ow"], 1.0) for r in rows]
    ys = [r["instr"] for r in rows]
    ata = [[sum(x[i] * x[j] for x in xs) for j in range(3)] for i in range(3)]
    aty = [sum(x[i] * y for x, y in zip(xs, ys)) for i in range(3)]
    for i in range(3):                                # Gauss-Jordan
        piv = ata[i][i]
        ata[i] = [v / piv for v in ata[i]]
        aty[i] /= piv
        for k in range(3):
            if k != i:
                f = ata[k][i]
                ata[k] = [a - f * b for a, b in zip(ata[k], ata[i])]
                aty[k] -= f * aty[i]
    return aty


def calibrate(cin):
    rows = []
    for oh, ow, cout in CAL_SHAPES:
        total, instr = build(oh, ow, cout, cin)
        rows.append({"oh": oh, "ow": ow, "cout": cout, "cin": cin, "elf_bytes": total, "tile_bytes": tile_bytes(oh, ow, cin, cout),
                     "macs": oh * ow * cout * 9 * cin, "outputs": oh * ow * cout, "instr": instr})
    fixed = max(r["elf_bytes"] - r["tile_bytes"] for r in rows)
    a, b, c = fit(rows)
    worst = max(abs(a * r["outputs"] + b * r["oh"] * r["ow"] + c - r["instr"]) / r["instr"] for r in rows)
    cal = {"program": PROGRAM, "cin": cin, "fixed_bytes": fixed, "a": a, "b": b, "c": c, "max_fit_error": worst, "runs": rows}
    CAL.parent.mkdir(exist_ok=True)
    CAL.write_text(json.dumps(cal, indent=1))
    for r in rows:
        print(f"  {r['oh']}x{r['ow']}x{r['cout']:<3} ELF {r['elf_bytes']:6} B = tile {r['tile_bytes']:6} + {r['elf_bytes'] - r['tile_bytes']:5}"
              f"   {r['instr']:9,} instructions")
    print(f"fixed part (code, stack, rest) <= {fixed} B; instructions per tile = {a:.1f} * outputs + {b:.1f} * pixels + {c:.0f} "
          f"(worst fit error {worst:.1%}) -> {CAL.relative_to(ROOT)}")


def plan(args):
    if not CAL.exists():
        raise SystemExit("run --calibrate first")
    cal = json.loads(CAL.read_text())
    if cal["cin"] != args.cin:
        raise SystemExit(f"calibrated for CIN {cal['cin']}, not {args.cin}; run --calibrate --cin {args.cin}")
    budget = args.mem_kib * 1024 - cal["fixed_bytes"] - args.margin
    a, b, c = cal["a"], cal["b"], cal["c"]
    cands = []
    for cout in range(4, args.cout + 1, 4):
        if args.cout % cout:
            continue
        for oh in range(2, 129, 2):
            for ow in range(2, 129, 2):
                if args.h % oh or args.w % ow:
                    continue
                need = tile_bytes(oh, ow, args.cin, cout)
                if need > budget:
                    continue
                tiles = (args.h // oh) * (args.w // ow) * (args.cout // cout)
                per = a * oh * ow * cout + b * oh * ow + c
                halo = (oh + 2) * (ow + 2) / (oh * ow)
                # sent per tile: input with halo, weights, bias and requant parameters; returned: the pooled output
                moved = tiles * ((oh + 2) * (ow + 2) * args.cin + cout * 9 * args.cin + 8 * cout + (oh // 2) * (ow // 2) * cout)
                cands.append((moved, tiles * per, oh, ow, cout, need, tiles, per, halo))
    cands.sort()
    macs = args.h * args.w * args.cout * 9 * args.cin
    print(f"layer {args.h}x{args.w}, CIN {args.cin}, COUT {args.cout}: {macs / 1e9:.2f} G MACs; "
          f"data budget {budget} B of {args.mem_kib} KiB (fixed {cal['fixed_bytes']} B, margin {args.margin} B)")
    print(f"{'tile OHxOWxCOUT':>16} {'bytes':>6} {'tiles':>7} {'halo':>5} {'instr/tile':>11} {'layer instr':>12} {'moved MB':>9}")
    for moved, total, oh, ow, cout, need, tiles, per, halo in cands[:args.top]:
        print(f"{f'{oh}x{ow}x{cout}':>16} {need:6} {tiles:7} {halo:5.2f} {per:11,.0f} {total / 1e9:10.2f} G {moved / 1e6:9.1f}")
    full = [c for c in cands if c[4] == args.cout]
    if full:
        best = max(full, key=lambda c: c[2] * c[3])
        print(f"largest tile with all {args.cout} output channels: {best[2]}x{best[3]}x{best[4]} ({best[5]} B)")
    else:
        print(f"no tile with all {args.cout} output channels fits")
    return cands


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--calibrate", action="store_true")
    ap.add_argument("--check", nargs=3, type=int, metavar=("OH", "OW", "COUT"))
    ap.add_argument("--mem-kib", type=int, default=32)
    ap.add_argument("--margin", type=int, default=256, help="bytes kept free below the stack (default 256)")
    ap.add_argument("--h", type=int, default=512)
    ap.add_argument("--w", type=int, default=512)
    ap.add_argument("--cin", type=int, default=32)
    ap.add_argument("--cout", type=int, default=32)
    ap.add_argument("--top", type=int, default=8)
    args = ap.parse_args()
    if args.calibrate:
        calibrate(args.cin)
    elif args.check:
        oh, ow, cout = args.check
        try:
            total, instr = build(oh, ow, cout, args.cin)
        except subprocess.CalledProcessError as e:
            overflow = re.search(r"overflowed by (\d+) bytes", e.stderr or "")
            print(f"{oh}x{ow}x{cout}: does NOT link in {args.mem_kib} KiB"
                  + (f" (over by {overflow.group(1)} B)" if overflow else f": {(e.stderr or '').strip()[-200:]}"))
            sys.exit(1)
        ok = total + args.margin <= args.mem_kib * 1024
        print(f"{oh}x{ow}x{cout}: ELF {total} B of {args.mem_kib * 1024} ({'fits' if ok else 'does NOT fit'}), "
              f"PASS in {instr:,} instructions")
        sys.exit(0 if ok else 1)
    else:
        plan(args)


if __name__ == "__main__":
    main()
