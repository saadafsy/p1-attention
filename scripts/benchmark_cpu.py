#!/usr/bin/env python3
"""Phase 2 benchmark, CPU side: time the C++ golden model per inference.

Produces build/cpu_baseline.txt with per-N wall-clock (median of repeats) for
the same attention computation the RTL performs. Pairs with
tb/attention_top/cycles.txt (accelerator cycle counts from the cocotb TB) to
form the benchmark table in docs/benchmark.md. Methodology notes:
- attn_cpp is the bit-exact golden model compiled -O2, single-threaded; this
  is a golden-model baseline, NOT a tuned BLAS kernel, and the table must say
  so (honest apples-to-oranges labeling).
- Timing excludes process startup and file I/O: attn_cpp is timed around many
  repetitions of run() via an added --bench flag? No: to keep model/attn.cpp
  untouched, we time full process invocations and subtract the measured
  no-work baseline (N=1) startup cost, reporting both raw and adjusted.
"""

import pathlib
import random
import statistics
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "model"))
import attn  # noqa: E402

BUILD = ROOT / "build" / "model"
CPP_BIN = BUILD / "attn_cpp"
LUT = ROOT / "model" / "exp_lut.hex"
OUT = ROOT / "build" / "cpu_baseline.txt"
REPS = 15


def write_stim(path, q, k, v):
    with open(path, "w") as f:
        f.write(f"{len(q)} {attn.D_DIM}\n")
        for mat in (q, k, v):
            for row in mat:
                f.write(" ".join(str(x) for x in row) + "\n")


def time_case(n, seed):
    rng = random.Random(seed)
    gen = lambda: [[rng.randint(-128, 127) for _ in range(attn.D_DIM)]
                   for _ in range(n)]
    stim = BUILD / f"bench_n{n}.txt"
    out = BUILD / f"bench_n{n}.out"
    write_stim(stim, gen(), gen(), gen())
    times = []
    for _ in range(REPS):
        t0 = time.perf_counter()
        subprocess.run([str(CPP_BIN), str(LUT), str(stim), str(out)],
                       check=True)
        times.append(time.perf_counter() - t0)
    return statistics.median(times)


def main():
    if not CPP_BIN.exists():
        print("attn_cpp not built; run 'make model-check' first")
        return 1
    BUILD.mkdir(parents=True, exist_ok=True)
    lines = ["# CPU golden-model baseline (attn.cpp, -O2, single thread)",
             "# median of %d full-process runs; proc_overhead row is the" % REPS,
             "# N=1 run (startup + I/O floor) for adjustment",
             "# N   median_ms"]
    floor = time_case(1, 100)
    lines.append(f"proc_overhead {floor*1e3:.3f}")
    for n in (4, 8, 16, 32, 64):
        t = time_case(n, n)
        lines.append(f"{n} {t*1e3:.3f}")
        print(f"N={n:3d}: {t*1e3:8.3f} ms (raw, incl. ~{floor*1e3:.3f} ms process floor)")
    OUT.write_text("\n".join(lines) + "\n")
    print(f"written: {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
