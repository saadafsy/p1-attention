#!/usr/bin/env python3
"""Bit-accurate fixed-point golden model for the streaming attention engine.

NORMATIVE reference: docs/uarch.md. Constants and every rounding/saturation
site here implement that spec one to one; if they disagree, uarch.md wins.

The integer core uses plain Python ints (arbitrary precision) with explicit
range asserts that mirror the RTL register widths, so any overflow of a
declared width is an assertion failure, never a silent wrap.

Python note: '>>' and '//' on negative ints are floor operations, which is
exactly the arithmetic-shift / floor-division semantics the spec requires.
"""

import argparse
import math

# ---- Normative constants (docs/uarch.md sections 1-3) ----------------------
D_DIM = 16          # head dimension
D_SHIFT = 2         # log2(sqrt(D_DIM)); 1/sqrt(D) is an exact shift
N_MAX = 256         # architectural max sequence length

ACT_FRAC = 6        # Q1.6   inputs / output
SCORE_FRAC = 10     # Q5.10  scores and running max
W_FRAC = 15         # UQ1.15 exp output
LUT_SIZE = 1024     # 10-bit index
LUT_STEP_SHIFT = 4  # Q5.10 diff -> 2^-6 index grid is >>4
LUT_DOMAIN_RAW = -16384   # -16.0 in Q5.10, LUT domain clamp

M_INIT = -32768     # most negative SCORE, running-max init
EXP_ONE = 32768     # exp(0) in UQ1.15


# ---- exp LUT (normative table, docs/uarch.md 3.5) ---------------------------
def gen_exp_lut():
    """lut[j] = floor(2^15 * exp(-j/2^6) + 0.5), j = 0..1023."""
    lut = [math.floor(32768.0 * math.exp(-(j / 64.0)) + 0.5) for j in range(LUT_SIZE)]
    assert lut[0] == EXP_ONE
    assert lut[709] == 1 and lut[710] == 0, "zero tail must start at j=710"
    assert all(lut[i] >= lut[i + 1] for i in range(LUT_SIZE - 1)), "must be monotone"
    return lut


def emit_lut(path):
    """Write the normative hex table consumed by attn.cpp and later by RTL
    ($readmemh): 1024 lines, 4 lowercase hex digits each."""
    lut = gen_exp_lut()
    with open(path, "w") as f:
        for v in lut:
            f.write(f"{v:04x}\n")
    return lut


# ---- Rounding helpers (docs/uarch.md section 4) ------------------------------
def rshr(x, k):
    """Round-half-up arithmetic right shift: floor(x/2^k + 1/2)."""
    return (x + (1 << (k - 1))) >> k


def divr(a, b):
    """Round-half-up division a/b for b > 0: floor((2a+b)/(2b))."""
    return (2 * a + b) // (2 * b)


def lut_index(d_raw):
    """Q5.10 difference (<= 0) to LUT index. Clamp to domain, round to grid."""
    assert d_raw <= 0
    if d_raw < LUT_DOMAIN_RAW:
        d_raw = LUT_DOMAIN_RAW
    idx = (-d_raw + 8) >> LUT_STEP_SHIFT
    return idx if idx < LUT_SIZE else LUT_SIZE - 1


def sat(x, lo, hi):
    return lo if x < lo else hi if x > hi else x


# ---- Fixed-point core (docs/uarch.md section 6, the RTL contract) -----------
def attn_fixed(q_mat, k_mat, v_mat, lut, trace=None):
    """Streaming attention, bit-exact. Inputs are N x D lists of Q1.6 raw ints
    in [-128, 127]; returns N x D list of Q1.6 raw ints.

    If trace is a list, (i, j, m, l, acc-tuple) is appended after every step
    (debug aid for the Phase 1+ testbenches)."""
    n = len(q_mat)
    d = len(q_mat[0])
    assert 1 <= n <= N_MAX, f"N={n} outside [1, {N_MAX}]"
    assert d == D_DIM, f"D={d}, spec fixes D={D_DIM}"
    for mat in (q_mat, k_mat, v_mat):
        assert len(mat) == n and all(len(r) == d for r in mat)
        assert all(-128 <= x <= 127 for r in mat for x in r), "inputs must be int8"

    out = []
    for i in range(n):
        m = M_INIT
        l = 0
        acc = [0] * d
        for j in range(n):
            # MAC: exact 24-bit dot product (SACC, Q11.12)
            sacc = 0
            for dd in range(d):
                sacc += q_mat[i][dd] * k_mat[j][dd]
            assert -(1 << 23) <= sacc < (1 << 23), "SACC width violated"

            # score: one rounding, frac 12->10 plus /sqrt(D) (rounding site 1)
            s = sat(rshr(sacc, 2 + D_SHIFT), -32768, 32767)

            # online softmax step (rounding sites 2, 3, 4)
            m_new = m if m >= s else s
            r = lut[lut_index(m - m_new)]
            w = lut[lut_index(s - m_new)]
            l = rshr(l * r, W_FRAC) + w
            assert 0 <= l < (1 << 24), "DEN width violated"
            for dd in range(d):
                acc[dd] = rshr(acc[dd] * r, W_FRAC) + w * v_mat[j][dd]
                assert -(1 << 31) <= acc[dd] < (1 << 31), "NUM width violated"
            m = m_new
            if trace is not None:
                trace.append((i, j, m, l, tuple(acc)))

        # output: scale-cancelling division (rounding site 5), defensive sat
        assert l >= EXP_ONE, "denominator must be >= exp(0)"
        out.append([sat(divr(acc[dd], l), -128, 127) for dd in range(d)])
    return out


# ---- Float reference (NumPy), for the error budget only ---------------------
def attn_float(q_mat, k_mat, v_mat):
    """IEEE double attention on the dequantized inputs. NOT bit-exact and not
    a golden model; used only to measure the docs/uarch.md section 7 budget."""
    import numpy as np

    qf = np.array(q_mat, dtype=np.float64) / (1 << ACT_FRAC)
    kf = np.array(k_mat, dtype=np.float64) / (1 << ACT_FRAC)
    vf = np.array(v_mat, dtype=np.float64) / (1 << ACT_FRAC)
    s = (qf @ kf.T) / math.sqrt(D_DIM)
    s = s - s.max(axis=1, keepdims=True)
    p = np.exp(s)
    p = p / p.sum(axis=1, keepdims=True)
    return p @ vf


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--emit-lut", metavar="PATH",
                    help="write the normative exp LUT hex table and exit")
    args = ap.parse_args()
    if args.emit_lut:
        emit_lut(args.emit_lut)
        print(f"exp LUT written: {args.emit_lut} ({LUT_SIZE} x 16 bit)")
        return
    ap.print_help()


if __name__ == "__main__":
    main()
