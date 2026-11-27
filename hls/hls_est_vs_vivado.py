#!/usr/bin/env python3
"""HLS resource estimate (Vitis HLS csynth.rpt) vs Vivado out-of-context synthesis (vsynth_util.rpt).

Read-only: walks the hls4ml project folders, takes the top-level "Total" row of solution1/syn/report/csynth.rpt
(BRAM_18K, DSP, FF, LUT) and the Vivado utilization report (Slice LUTs, Slice Registers / Register as Flip Flop,
DSPs, Block RAM Tile), and prints one CSV row per project with the ratio Vivado / HLS.
usage: hls_est_vs_vivado.py <root> [<root> ...] > out.csv
"""
import re
import sys
from pathlib import Path


def hls_total(rpt):
    t = rpt.read_text(errors="replace")
    sec = t.split("== Utilization Estimates", 1)
    if len(sec) < 2:
        return None
    hdr = next((l for l in sec[1].splitlines() if re.match(r"\|\s*Name\s*\|", l)), None)
    tot = next((l for l in sec[1].splitlines() if re.match(r"\|\s*Total\s*\|", l)), None)
    if not hdr or not tot:
        return None
    names = [c.strip() for c in hdr.strip("|").split("|")]
    vals = [c.strip() for c in tot.strip("|").split("|")]
    d = dict(zip(names, vals))
    def get(*keys):
        for k in keys:
            for n, v in d.items():
                if n.upper().startswith(k):
                    return float(v)
        return None
    return {"lut": get("LUT"), "ff": get("FF"), "dsp": get("DSP"), "bram18": get("BRAM")}


def viv_util(rpt):
    t = rpt.read_text(errors="replace")
    def used(label):
        m = re.search(r"\|\s*" + re.escape(label) + r"\*?\s*\|\s*([\d.]+)\s*\|", t)
        return float(m.group(1)) if m else None
    return {"lut": used("Slice LUTs") or used("CLB LUTs"),
            "ff": used("Slice Registers") or used("Register as Flip Flop") or used("CLB Registers"),
            "dsp": used("DSPs"), "bram_tile": used("Block RAM Tile")}


def main():
    print("project,hls_lut,viv_lut,lut_ratio,hls_ff,viv_ff,ff_ratio,hls_dsp,viv_dsp,hls_bram18,viv_bram_tile,bram18_ratio")
    for root in sys.argv[1:]:
        for viv in sorted(Path(root).glob("**/vsynth_util.rpt")):
            proj = viv.parent
            # the top function's report holds the totals of all sub-functions, so take the largest LUT total
            hs = [x for x in (hls_total(p) for p in proj.glob("**/solution1/syn/report/*_csynth.rpt")) if x and x["lut"]]
            if not hs:
                continue
            h, v = max(hs, key=lambda x: x["lut"]), viv_util(viv)
            if not v["lut"]:
                continue
            r = lambda a, b: f"{a / b:.3f}" if a is not None and b else ""
            print(f"{proj.relative_to(Path(root).parent)},{h['lut']:.0f},{v['lut']:.0f},{r(v['lut'], h['lut'])},"
                  f"{h['ff']:.0f},{v['ff']:.0f},{r(v['ff'], h['ff'])},{h['dsp']:.0f},{v['dsp']:.0f},"
                  f"{h['bram18']:.0f},{v['bram_tile']},{r(2 * v['bram_tile'], h['bram18']) if v['bram_tile'] is not None else ''}")


if __name__ == "__main__":
    main()
