#!/usr/bin/env python3
"""Accuracy and throughput of the fixed-point engine.

Accuracy: the bit-exact model (model/attn.py attn_fixed, which the RTL
matches cycle for cycle in tb/attention_top) against float64 attention on
the same dequantized inputs. Errors are in output LSBs (Q1.6, 1 LSB = 1/64).
The unavoidable floor is 0.5 LSB: that is what rounding an exact float
answer to Q1.6 costs.

Throughput: from the cycle formula cycles = nblk*(16*nblk+156)+1, nblk = N/4
(docs/uarch.md 8.3, checked exactly by tb/attention_top). MACs per inference
are N^2*D for Q.K^T plus N^2*D for P.V.

Usage: python3 scripts/accuracy.py [--seeds 20] [--out build/accuracy.txt]
"""

import argparse
import pathlib
import random
import sys

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "model"))
import attn  # noqa: E402

D = attn.D_DIM
LSB = 1 << attn.ACT_FRAC


def gen(rng, n, dist):
    if dist == "uniform":
        return [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
    # "gauss": activations around +-0.5 (sigma 32 raw), clipped to int8
    return [[max(-128, min(127, round(rng.gauss(0, 32)))) for _ in range(D)] for _ in range(n)]


def cycles(n):
    nblk = n // 4
    return nblk * (16 * nblk + 156) + 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=20)
    ap.add_argument("--out", default=str(ROOT / "build" / "accuracy.txt"))
    a = ap.parse_args()
    lut = attn.gen_exp_lut()

    lines = ["# Accuracy vs float64 (errors in Q1.6 LSBs; 0.5 LSB is the rounding floor)",
             "| inputs | N | max err | mean err | within 1 LSB | exact vs rounded float |",
             "|--------|---|---------|----------|--------------|------------------------|"]
    for dist in ("uniform", "gauss"):
        for n in (4, 16, 64):
            errs, exact = [], 0
            for seed in range(a.seeds):
                rng = random.Random(1000 * n + seed + (0 if dist == "uniform" else 7))
                q, k, v = gen(rng, n, dist), gen(rng, n, dist), gen(rng, n, dist)
                fx = np.array(attn.attn_fixed(q, k, v, lut), dtype=np.float64)
                fl = np.asarray(attn.attn_float(q, k, v)) * LSB
                e = np.abs(fx - fl)
                errs.append(e)
                exact += int(np.sum(fx == np.clip(np.floor(fl + 0.5), -128, 127)))
            e = np.concatenate([x.ravel() for x in errs])
            lines.append(f"| {dist} | {n} | {e.max():.2f} | {e.mean():.3f} | "
                         f"{100.0 * np.mean(e <= 1.0):.1f}% | {100.0 * exact / e.size:.1f}% |")

    lines += ["", "# Throughput (cycle formula, clock-free)",
              "| N | cycles | MACs | MAC/cycle | of 32 MAC units | exp lookups/cycle |",
              "|---|--------|------|-----------|-----------------|-------------------|"]
    for n in (4, 8, 16, 32, 64):
        c = cycles(n)
        macs = 2 * n * n * D
        lines.append(f"| {n} | {c} | {macs} | {macs / c:.1f} | {100.0 * macs / c / 32:.0f}% | "
                     f"{n * n / c:.2f} |")

    text = "\n".join(lines) + "\n"
    pathlib.Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(a.out).write_text(text)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
