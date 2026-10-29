#!/usr/bin/env python3
"""Accuracy of the fixed-point engine vs a float reference, plus MAC/cycle.

Run from the repo root: python scripts/accuracy_report.py [--trials T]
Accuracy: attn_fixed (bit-exact to the RTL) vs attn_float (IEEE double on the
dequantized inputs), error in output LSBs (1 LSB = 2^-6). Cycle counts come
from tb/attention_top/cycles.txt (simulation facts, no clock involved).
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "model"))
import attn  # noqa: E402

CYCLES = os.path.join(os.path.dirname(__file__), "..", "tb", "attention_top",
                      "cycles.txt")


def load_cycles():
    out = {}
    for line in open(CYCLES):
        if line.strip() and not line.startswith("#"):
            n, c = line.split()
            out[int(n)] = int(c)
    return out


def rand_mat(rng, n, lo, hi):
    return [[rng.randint(lo, hi) for _ in range(attn.D_DIM)] for _ in range(n)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trials", type=int, default=20)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    rng = random.Random(args.seed)
    lut = attn.gen_exp_lut()
    cycles = load_cycles()
    print("| N | input range | trials | max abs err (LSB) | mean abs err (LSB) | cycles | MAC/cycle |")
    print("|---|-------------|--------|-------------------|--------------------|--------|-----------|")
    for n in (4, 16, 64):
        for name, lo, hi in (("full int8", -128, 127), ("small +-32", -32, 32)):
            mx, tot, cnt = 0.0, 0.0, 0
            for _ in range(args.trials):
                q, k, v = (rand_mat(rng, n, lo, hi) for _ in range(3))
                fx = attn.attn_fixed(q, k, v, lut)
                fl = attn.attn_float(q, k, v)
                for i in range(n):
                    for d in range(attn.D_DIM):
                        e = abs(fx[i][d] - fl[i][d] * (1 << attn.ACT_FRAC))
                        mx = max(mx, e)
                        tot += e
                        cnt += 1
            macs = 2 * n * n * attn.D_DIM
            print(f"| {n} | {name} | {args.trials} | {mx:.3f} | {tot / cnt:.4f} "
                  f"| {cycles[n]} | {macs / cycles[n]:.1f} |")


if __name__ == "__main__":
    main()
