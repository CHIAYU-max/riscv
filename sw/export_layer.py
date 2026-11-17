#!/usr/bin/env python3
"""Export one 3x3 convolution of a trained PyTorch U-Net as INT8 data for sw/c/gen_block.py --weights.

The BatchNorm that follows the convolution is folded into it (w * g / sqrt(v + eps), b = beta - mean * g / sqrt(v + eps)),
then the weights are quantized per output channel to s8 (symmetric, scale = max |w| / 127) and the bias to int32 at
scale act_scale * weight_scale, the same scheme as the block benchmark (u8 activations, s8 weights, int32 accumulator).
Only the first --cout output channels are kept so the tile fits the core's 8 KiB data memory.

Runs where the checkpoint is (needs torch). The output holds trained weights: keep it out of the repository
(build/ is ignored) unless the model's data owner agrees to publish it.

usage: export_layer.py <checkpoint.pth> --conv head.0.block.3 --bn head.0.block.4 --cout 8 --out layer.json
"""
import argparse
import json

import torch


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("ckpt")
    ap.add_argument("--conv", default="head.0.block.3", help="state_dict prefix of the 3x3 convolution")
    ap.add_argument("--bn", default="head.0.block.4", help="state_dict prefix of the BatchNorm after it ('' = none)")
    ap.add_argument("--cout", type=int, default=8, help="output channels to keep (multiple of 4)")
    ap.add_argument("--act-max", type=float, default=4.0,
                    help="real value of the u8 activation 255 (sets the bias scale; the input tile is synthetic)")
    ap.add_argument("--eps", type=float, default=1e-5)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    sd = torch.load(args.ckpt, map_location="cpu", weights_only=False)
    sd = sd.get("model_state_dict", sd)
    w = sd[f"{args.conv}.weight"].double()                    # [cout, cin, 3, 3]
    b = sd.get(f"{args.conv}.bias", torch.zeros(w.shape[0])).double()
    assert w.shape[2:] == (3, 3), w.shape
    if args.bn:
        g, beta = sd[f"{args.bn}.weight"].double(), sd[f"{args.bn}.bias"].double()
        mean, var = sd[f"{args.bn}.running_mean"].double(), sd[f"{args.bn}.running_var"].double()
        k = g / torch.sqrt(var + args.eps)
        w, b = w * k[:, None, None, None], (b - mean) * k + beta
    cout, cin = args.cout, w.shape[1]
    assert cout % 4 == 0 and cout <= w.shape[0] and cin % 4 == 0, (cout, w.shape)
    w, b = w[:cout], b[:cout]

    act_scale = args.act_max / 255
    w_scale = w.abs().amax(dim=(1, 2, 3)) / 127
    wq = torch.clamp(torch.round(w / w_scale[:, None, None, None]), -128, 127).to(torch.int64)
    bq = torch.round(b / (act_scale * w_scale)).to(torch.int64)
    # HWC per output channel, as gen_block.py indexes it: ((oc * 3 + ky) * 3 + kx) * cin + c
    wq_hwc = wq.permute(0, 2, 3, 1).reshape(-1).tolist()
    err = (wq.double() * w_scale[:, None, None, None] - w).abs().max().item()
    with open(args.out, "w") as f:
        json.dump({"layer": args.conv, "bn": args.bn, "cin": cin, "cout": cout, "cout_total": int(sd[f"{args.conv}.weight"].shape[0]),
                   "act_scale": act_scale, "weight_scale": w_scale.tolist(), "max_weight_error": err,
                   "wgt": wq_hwc, "bias": bq.tolist()}, f)
    print(f"{args.conv}: cin {cin}, cout {cout} of {sd[f'{args.conv}.weight'].shape[0]}, "
          f"weight range {min(wq_hwc)}..{max(wq_hwc)}, bias range {min(bq.tolist())}..{max(bq.tolist())}, "
          f"max quantization error {err:.2e} -> {args.out}")


if __name__ == "__main__":
    main()
