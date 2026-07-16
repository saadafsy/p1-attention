#!/usr/bin/env python3
"""Phase 0 cross-check: prove model/attn.py and model/attn.cpp bit-identical.

Per the build sheet, the two golden models are unit-tested against each other
on random inputs (plus corner cases). Also measures the fixed-vs-float error
against the docs/uarch.md section 7 gate (6 LSB) as a sanity bound.

Exit 0 only if: cpp builds, every case is byte-exact between py and cpp, and
every case meets the float-error gate.
"""

import pathlib
import random
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "model"))
import attn  # noqa: E402

BUILD = ROOT / "build" / "model"
LUT_HEX = ROOT / "model" / "exp_lut.hex"
CPP_SRC = ROOT / "model" / "attn.cpp"
CPP_BIN = BUILD / "attn_cpp"
FLOAT_GATE_LSB = 6  # docs/uarch.md section 7

D = attn.D_DIM


def rand_case(n, seed, lo=-128, hi=127):
    rng = random.Random(seed)
    gen = lambda: [[rng.randint(lo, hi) for _ in range(D)] for _ in range(n)]
    return gen(), gen(), gen()


def monotonic_case(n):
    """Scores strictly increase with j: forces a running-max update (and a
    real rescale) on every single step. Worst case for rescale rounding."""
    q = [[64] * D for _ in range(n)]
    k = [[max(-128, min(127, -128 + 2 * j))] * D for j in range(n)]
    rng = random.Random(99)
    v = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
    return q, k, v


def const_case(n, val):
    m = [[val] * D for _ in range(n)]
    return [r[:] for r in m], [r[:] for r in m], [r[:] for r in m]


CASES = [
    ("rand-n64-s1", rand_case(64, 1)),
    ("rand-n64-s2", rand_case(64, 2)),
    ("rand-n64-s3", rand_case(64, 3)),
    ("rand-n64-s4", rand_case(64, 4)),
    ("rand-n64-s5", rand_case(64, 5)),
    ("rand-n1-s7", rand_case(1, 7)),
    ("rand-n2-s8", rand_case(2, 8)),
    ("rand-n17-s9", rand_case(17, 9)),
    ("rand-n256-s10", rand_case(256, 10)),        # architectural N_MAX
    ("small-mag-s11", rand_case(64, 11, -8, 8)),  # low-SNR regime
    ("zeros-n8", const_case(8, 0)),
    ("allmax-n8", const_case(8, 127)),            # extreme positive scores
    ("allmin-n8", const_case(8, -128)),           # extreme via (-128)^2
    ("monotonic-n64", monotonic_case(64)),        # max update every step
]


def write_stimulus(path, q, k, v):
    with open(path, "w") as f:
        f.write(f"{len(q)} {D}\n")
        for mat in (q, k, v):
            for row in mat:
                f.write(" ".join(str(x) for x in row) + "\n")


def main():
    BUILD.mkdir(parents=True, exist_ok=True)

    # 1. Emit the normative LUT (single source; cpp consumes this file).
    attn.emit_lut(LUT_HEX)

    # 2. Build the C++ model. Asserts stay on: no -DNDEBUG.
    cmd = ["g++", "-O2", "-std=c++17", "-Wall", "-Wextra",
           str(CPP_SRC), "-o", str(CPP_BIN)]
    print("$", " ".join(cmd))
    subprocess.run(cmd, check=True)

    lut = attn.gen_exp_lut()
    n_fail = 0
    worst_lsb = 0.0
    worst_name = ""
    print(f"{'case':<16} {'N':>4}  {'py==cpp':<8} {'max|fix-float|':>14}")
    for name, (q, k, v) in CASES:
        stim = BUILD / f"{name}.txt"
        cout = BUILD / f"{name}.out"
        write_stimulus(stim, q, k, v)

        py_out = attn.attn_fixed(q, k, v, lut)
        subprocess.run([str(CPP_BIN), str(LUT_HEX), str(stim), str(cout)],
                       check=True)
        cpp_out = [[int(x) for x in line.split()]
                   for line in cout.read_text().splitlines()]

        identical = py_out == cpp_out
        if not identical:
            n_fail += 1
            for i, (pr, cr) in enumerate(zip(py_out, cpp_out)):
                if pr != cr:
                    print(f"  MISMATCH {name} row {i}:\n   py : {pr}\n   cpp: {cr}")
                    break

        ref = attn.attn_float(q, k, v)
        max_lsb = max(
            abs(py_out[i][j] / 64.0 - ref[i][j]) * 64.0
            for i in range(len(py_out)) for j in range(D)
        )
        if max_lsb > worst_lsb:
            worst_lsb, worst_name = max_lsb, name
        gate_ok = max_lsb <= FLOAT_GATE_LSB
        if not gate_ok:
            n_fail += 1
        print(f"{name:<16} {len(q):>4}  {'OK' if identical else 'FAIL':<8} "
              f"{max_lsb:>10.2f} LSB{'' if gate_ok else '  > GATE'}")

    print(f"\nworst float deviation: {worst_lsb:.2f} LSB "
          f"({worst_lsb / 64.0:.4f} in value) on '{worst_name}', "
          f"gate {FLOAT_GATE_LSB} LSB")
    if n_fail:
        print(f"CROSSCHECK FAIL: {n_fail} failure(s)")
        return 1
    print(f"CROSSCHECK PASS: {len(CASES)} cases bit-identical, float gate met")
    return 0


if __name__ == "__main__":
    sys.exit(main())
