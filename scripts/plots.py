#!/usr/bin/env python3
"""Charts for the README, from the bit-exact model and measured numbers.

    python3 scripts/plots.py            # writes docs/img/accuracy_hist.png and docs/img/throughput.png

accuracy_hist.png: signed error of attn_fixed (the RTL contract, bit-exact to the
RTL in every testbench) against float64 attention, in output LSBs, N = 64, the
same 20 seeds per input distribution as scripts/accuracy.py.
throughput.png: MAC/cycle against N from the cycle formula (docs/uarch.md 8.3).
"""
import pathlib
import random
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "model"))
sys.path.insert(0, str(ROOT / "scripts"))
import attn  # noqa: E402
from accuracy import D, LSB, cycles, gen  # noqa: E402

OUT = ROOT / "docs" / "img"


def accuracy_hist(seeds=20, n=64):
    lut = attn.gen_exp_lut()
    fig, ax = plt.subplots(figsize=(7, 3.8), dpi=150)
    bins = np.arange(-1.0, 1.0001, 0.05)
    for dist, color in (("uniform", "#1f77b4"), ("gauss", "#d62728")):
        errs = []
        for seed in range(seeds):
            rng = random.Random(1000 * n + seed + (0 if dist == "uniform" else 7))
            q, k, v = gen(rng, n, dist), gen(rng, n, dist), gen(rng, n, dist)
            fx = np.array(attn.attn_fixed(q, k, v, lut), dtype=np.float64)
            fl = np.asarray(attn.attn_float(q, k, v)) * LSB
            errs.append((fx - fl).ravel())
        e = np.concatenate(errs)
        ax.hist(e, bins=bins, histtype="step", linewidth=1.6, color=color,
                label=f"{dist} inputs, max |err| {np.abs(e).max():.2f} LSB")
    ax.axvline(-0.5, color="#888", linestyle=":", linewidth=1)
    ax.axvline(0.5, color="#888", linestyle=":", linewidth=1)
    ax.set_xlabel("hardware output minus float64 attention (output LSBs)")
    ax.set_ylabel("outputs")
    ax.set_title(f"Accuracy vs float64, N = {n}, {seeds} seeds x {n}x{D} outputs each", loc="left", fontsize=10)
    ax.legend(frameon=False, fontsize=8, loc="upper center", bbox_to_anchor=(0.5, -0.22), ncol=2)
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    fig.savefig(OUT / "accuracy_hist.png", facecolor="white")
    print("wrote", OUT / "accuracy_hist.png")


def throughput():
    ns = [4, 8, 16, 32, 64]
    mpc = [2 * n * n * D / cycles(n) for n in ns]
    fig, ax = plt.subplots(figsize=(7, 3.0), dpi=150)
    ax.plot(ns, mpc, marker="o", color="#2ca02c")
    for n, m in zip(ns, mpc):
        ax.annotate(f"{m:.1f}", (n, m), textcoords="offset points", xytext=(0, 7), ha="center", fontsize=8)
    ax.axhline(32, color="#888", linestyle=":", linewidth=1)
    ax.text(4, 32.6, "32 MAC units (peak)", fontsize=8, color="#555")
    ax.set_xscale("log", base=2)
    ax.set_xticks(ns, [str(n) for n in ns])
    ax.set_ylim(0, 36)
    ax.set_xlabel("sequence length N")
    ax.set_ylabel("MAC per cycle")
    ax.set_title("Throughput from the cycle formula (simulation-verified at N = 4, 16, 64)", loc="left", fontsize=10)
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    fig.savefig(OUT / "throughput.png", facecolor="white")
    print("wrote", OUT / "throughput.png")


if __name__ == "__main__":
    accuracy_hist()
    throughput()
