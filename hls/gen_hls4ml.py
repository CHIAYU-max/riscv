#!/usr/bin/env python3
"""Generate hls4ml (Vitis HLS) projects for the U-Net block benchmark, as an HLS baseline for dot4 / requant.

Same block, same numbers as sw/c/gen_block.py: a 3x3 convolution on a 6x6x32 u8 tile (4x4 output, 8 output
channels, s8 weights, int32 bias) -> per-channel requant (acc * M / 2^shift, round half up, clamp 0..255) -> 2x2
max pooling. The requant is written as an hls4ml BatchNormalization with scale M / 2^shift and bias 0 whose result
type is ap_fixed<9,9,AP_RND,AP_SAT>, followed by a ReLU to ap_ufixed<8,8>; that is bit-exact with sw/iss.py's
requant as long as the product is kept at full precision (checked by the C simulation against the expected output
written by this script).

The input tile and requant parameters come from the same random sequence as gen_block.py (--seed), so the expected
output equals build/c/block_data.h's `expected` when gen_block.py runs with the same --weights and --seed.

--sparse24 prunes the weights to 2:4 along the input channels (keep the 2 largest |w| of every 4) before anything
else; that is a stand-in for the INT8 + 2:4 QAT model, whose layer can be exported with sw/export_layer.py instead.

Each --rf value gives one project: rf 1 = Latency strategy (fully unrolled), rf > 1 = Resource strategy.

usage: hls/gen_hls4ml.py --weights build/unet/unet_head0b3.json --out build/hls4ml [--rf 1 8 32] [--sparse24]
The output holds the trained weights (in firmware/weights): keep it out of the repository, like build/unet.
"""
import argparse
import json
import random
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "sw"))
from iss import requant  # noqa: E402

CIN_DEFAULT, OH, OW, COUT_DEFAULT = 32, 4, 4, 8
PART = "xc7a35tcpg236-1"  # Basys3


def requant_params(scale):
    """Same as sw/c/gen_block.py: M (u16) and shift with M / 2^shift ~= scale, M as large as possible."""
    shift = 31
    while shift > 0 and round(scale * (1 << shift)) > 0xFFFF:
        shift -= 1
    return round(scale * (1 << shift)), shift


def sparse24(wgt, cout, cin):
    """Keep the 2 largest |w| in every group of 4 consecutive input channels (HWC weight layout)."""
    w = list(wgt)
    for base in range(0, cout * 9 * cin, 4):
        group = sorted(range(base, base + 4), key=lambda i: (-abs(w[i]), i))
        for i in group[2:]:
            w[i] = 0
    return w


def block_data(layer, seed, prune):
    """Input tile, weights, bias, requant (M, shift) per channel and expected pooled output, all HWC."""
    cin, cout = layer["cin"], layer["cout"]
    rng = random.Random(seed)
    act = [rng.randint(0, 255) for _ in range((OH + 2) * (OW + 2) * cin)]
    for _ in range(cout * 9 * cin):  # gen_block.py draws random weights and bias before replacing them
        rng.randint(-128, 127)
    for _ in range(cout):
        rng.randint(-20000, 20000)
    wgt, bias = layer["wgt"], layer["bias"]
    if prune:
        wgt = sparse24(wgt, cout, cin)

    a = np.array(act, dtype=np.int64).reshape(OH + 2, OW + 2, cin)
    w = np.array(wgt, dtype=np.int64).reshape(cout, 3, 3, cin)
    acc = np.zeros((OH, OW, cout), dtype=np.int64)
    for oy in range(OH):
        for ox in range(OW):
            acc[oy, ox] = np.einsum("yxc,oyxc->o", a[oy:oy + 3, ox:ox + 3], w) + np.array(bias)

    mshift = [requant_params(320 / max(int(acc[..., oc].max()), 1)) for oc in range(cout)]
    out = np.zeros_like(acc)
    for oy in range(OH):
        for ox in range(OW):
            for oc in range(cout):
                m, s = mshift[oc]
                out[oy, ox, oc] = requant(int(acc[oy, ox, oc]) & 0xFFFF_FFFF, s << 16 | m)
    pooled = out.reshape(OH // 2, 2, OW // 2, 2, cout).max(axis=(1, 3))
    return dict(act=a, wgt=w, bias=np.array(bias), mshift=mshift, pooled=pooled,
                zeros=int((w == 0).sum()), acc_max=int(np.abs(acc).max()))


def build_model(d, cin, cout):
    import torch
    import torch.nn as nn

    class Block(nn.Module):
        def __init__(self):
            super().__init__()
            self.conv = nn.Conv2d(cin, cout, 3, bias=True)
            self.bn = nn.BatchNorm2d(cout, eps=0.0)  # var 1, mean 0, eps 0: scale = gamma exactly
            self.relu = nn.ReLU()
            self.pool = nn.MaxPool2d(2)

        def forward(self, x):
            return self.pool(self.relu(self.bn(self.conv(x))))

    m = Block().eval()
    with torch.no_grad():
        m.conv.weight.copy_(torch.tensor(d["wgt"].transpose(0, 3, 1, 2), dtype=torch.float64))  # OIHW
        m.conv.bias.copy_(torch.tensor(d["bias"], dtype=torch.float64))
        m.bn.weight.copy_(torch.tensor([mm / (1 << s) for mm, s in d["mshift"]], dtype=torch.float64))
        m.bn.bias.zero_()
        m.bn.running_mean.zero_()
        m.bn.running_var.fill_(1.0)
    return m.double()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--weights", required=True, help="JSON from sw/export_layer.py")
    ap.add_argument("--out", required=True)
    ap.add_argument("--rf", type=int, nargs="+", default=[1, 8, 32], help="reuse factors, one project each")
    ap.add_argument("--io", default="io_parallel", choices=["io_parallel", "io_stream"])
    ap.add_argument("--sparse24", action="store_true")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--clock", type=float, default=10.0, help="clock period in ns (Basys3: 100 MHz)")
    args = ap.parse_args()

    import hls4ml

    layer = json.load(open(args.weights))
    cin, cout = layer["cin"], layer["cout"]
    d = block_data(layer, args.seed, args.sparse24)
    out_root = Path(args.out)
    out_root.mkdir(parents=True, exist_ok=True)

    tag = ("s24_" if args.sparse24 else "") + ("st_" if args.io == "io_stream" else "")
    # test bench data, channels last (HWC), one sample per line
    tb_in, tb_out = out_root / f"{tag}tb_input.dat", out_root / f"{tag}tb_output.dat"
    tb_in.write_text(" ".join(map(str, d["act"].reshape(-1))) + "\n")
    tb_out.write_text(" ".join(map(str, d["pooled"].reshape(-1))) + "\n")

    model = build_model(d, cin, cout)
    max_shift = max(s for _, s in d["mshift"])
    summary = {"layer": layer["layer"], "cin": cin, "cout": cout, "oh": OH, "ow": OW, "macs": cout * OH * OW * 9 * cin,
               "sparse24": args.sparse24, "zero_weights": d["zeros"], "acc_max": d["acc_max"],
               "requant": d["mshift"], "projects": []}

    for rf in args.rf:
        cfg = hls4ml.utils.config_from_pytorch_model(
            model, input_shape=(cin, OH + 2, OW + 2), granularity="name", backend="Vitis",
            default_precision="ap_fixed<32,32>", default_reuse_factor=rf,
            channels_last_conversion="internal", transpose_outputs=False)
        cfg["Model"]["Strategy"] = "Latency" if rf == 1 else "Resource"
        cfg["SkipOptimizers"] = ["fuse_batchnorm"]  # folding the requant into the weights would lose bit-exactness
        lc = cfg["LayerName"]
        names = list(lc)
        inp = next(n for n in names if "input" in n.lower() or n == "x")
        conv, bn, relu, pool = (next(n for n in names if key in n) for key in ("conv", "bn", "relu", "pool"))
        lc[inp]["Precision"] = {"result": "ap_ufixed<8,8>"}
        lc[conv]["Precision"] = {"weight": "ap_fixed<8,8>", "bias": "ap_fixed<32,32>",
                                 "accum": "ap_fixed<32,32>", "result": "ap_fixed<32,32>"}
        lc[bn]["Precision"] = {"scale": f"ap_ufixed<{16 + max_shift},16>", "bias": "ap_fixed<2,2>",
                               "result": "ap_fixed<9,9,AP_RND,AP_SAT>"}
        lc[relu]["Precision"] = {"result": "ap_ufixed<8,8>"}
        lc[pool]["Precision"] = {"result": "ap_ufixed<8,8>"}
        for n in (conv, bn, relu, pool):
            lc[n]["ReuseFactor"] = rf
        if args.io == "io_stream":
            lc[conv]["ConvImplementation"] = "LineBuffer"

        prj = out_root / f"{tag}rf{rf}"
        hm = hls4ml.converters.convert_from_pytorch_model(
            model, hls_config=cfg, output_dir=str(prj), project_name="unet_block", backend="Vitis",  # "block" is a VHDL keyword
            part=PART, clock_period=args.clock, io_type=args.io,
            input_data_tb=str(tb_in), output_data_tb=str(tb_out))
        hm.write()
        summary["projects"].append({"name": prj.name, "rf": rf, "strategy": cfg["Model"]["Strategy"], "io": args.io})
        print(f"{prj}: rf {rf} ({cfg['Model']['Strategy']}), {args.io}")

    (out_root / f"{tag}summary.json").write_text(json.dumps(summary, indent=1))
    print(f"{summary['macs']} MACs, {d['zeros']} zero weights, requant {d['mshift']}")


if __name__ == "__main__":
    main()
