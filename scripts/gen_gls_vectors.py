#!/usr/bin/env python3
"""Write GLS stimulus and expected online_softmax port vectors into build/.

gls_stim.hex: {rst, in_valid, row_start, s[15:0]} per cycle (fixed seed).
gls_expected_lat{1,2}.hex: {m, l[23:0], r, w, out_valid} per cycle for PIPE_ROM=0/1,
from a port-level mirror of docs/uarch.md 8.2/8.2.1 (not the RTL).
"""
import random
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "model"))
import attn  # noqa: E402

LUT = attn.gen_exp_lut()
M_INIT = attn.M_INIT  # -32768
SMIN, SMAX = -32768, 32767


def step(m, l, s, row_start):
    """One uarch.md section 6 / 8.2 recurrence step on Python ints."""
    m_base = M_INIT if row_start else m
    l_base = 0 if row_start else l
    m_new = m_base if m_base >= s else s
    r = LUT[attn.lut_index(m_base - m_new)]
    w = LUT[attn.lut_index(s - m_new)]
    l_new = attn.rshr(l_base * r, attn.W_FRAC) + w
    assert 0 <= l_new < (1 << 24), f"DEN bound violated: {l_new}"
    return m_new, l_new, w, r


def build_stimulus():
    """Return list of (rst, in_valid, row_start, s) per cycle."""
    rng = random.Random(42)
    cyc = []
    for _ in range(3):
        cyc.append((1, 0, 0, 0))
    cyc.append((0, 0, 0, 0))  # one idle cycle after reset

    def row(length, bubbles=(), scores=None):
        """Append one row; a 1-cycle in_valid gap follows each element index in bubbles."""
        for i in range(length):
            s = scores[i] if scores else rng.randint(SMIN, SMAX)
            cyc.append((0, 1, 1 if i == 0 else 0, s))
            if i in bubbles:
                cyc.append((0, 0, 0, rng.randint(SMIN, SMAX)))  # s is dont-care

    # Directed: back-to-back rows, lengths 1 and 2 straddle the pipe depth.
    row(3)
    row(1)          # length-1 row back to back after a row
    row(1)          # two length-1 rows back to back
    row(2)
    row(4, bubbles={0})          # bubble immediately after row_start
    row(5, bubbles={2})          # bubble mid-row
    row(16)
    for _ in range(4):
        cyc.append((0, 0, 0, 0))
    row(8, bubbles={6})
    # DEN worst case: 256 elements at the max score drive l to 2^23.
    row(256, scores=[SMAX] * 256)
    for _ in range(24):
        ln = rng.choice([1, 1, 2, 3, 4, 7, 8, 15, 16, 31])
        bset = {i for i in range(ln) if rng.random() < 0.15}
        row(ln, bubbles=bset)
    for _ in range(4):
        cyc.append((0, 0, 0, 0))
    return cyc


def expected_lat1(cyc):
    """Port-level mirror of 8.2 (PIPE_ROM=0): out_valid latency 1."""
    m, l, w, r, ov = M_INIT, 0, 0, 0, 0
    out = []
    for (rst, iv, rs, s) in cyc:
        out.append((m, l, r, w, ov))  # visible DURING this cycle
        if rst:
            m, l, w, r, ov = M_INIT, 0, 0, 0, 0
        else:
            ov = iv
            if iv:
                m, l, w, r = step(m, l, to_signed(s), rs)
    return out


def expected_lat2(cyc):
    """Port-level mirror of 8.2.1 (PIPE_ROM=1): out_valid latency 2, m latency 1."""
    m, l, w, r, ov = M_INIT, 0, 0, 0, 0
    w_p, r_p, v_p, rs_p = 0, 0, 0, 0
    out = []
    for (rst, iv, rs, s) in cyc:
        out.append((m, l, r, w, ov))
        if rst:
            m, l, w, r, ov = M_INIT, 0, 0, 0, 0
            w_p, r_p, v_p, rs_p = 0, 0, 0, 0
            continue
        sv = to_signed(s)
        m_base = M_INIT if rs else m
        m_n = m_base if m_base >= sv else sv
        r_e = LUT[attn.lut_index(m_base - m_n)]
        w_e = LUT[attn.lut_index(sv - m_n)]
        if v_p:  # stage 2 commit uses the current l and pipe regs
            l_base = 0 if rs_p else l
            l = attn.rshr(l_base * r_p, attn.W_FRAC) + w_p
            w, r = w_p, r_p
        ov = v_p  # unconditional: falls when no element retires
        v_p = iv
        if iv:
            w_p, r_p, rs_p, m = w_e, r_e, rs, m_n
    return out


def to_signed(x):
    return x - 65536 if x >= 32768 else x


def to_u16(x):
    return x & 0xFFFF


def read_stimulus(path):
    """Parse gls_stim.hex (inverse of the writer), for --stim."""
    cyc = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        v = int(line, 16)
        cyc.append(((v >> 18) & 1, (v >> 17) & 1, (v >> 16) & 1, v & 0xFFFF))
    return cyc


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--stim", help="read this stimulus file instead of generating one")
    ap.add_argument("--out-dir", default=str(REPO / "build"))
    a = ap.parse_args(argv)
    build = Path(a.out_dir)
    build.mkdir(parents=True, exist_ok=True)
    if a.stim:
        cyc = read_stimulus(a.stim)
    else:
        cyc = build_stimulus()
        with open(build / "gls_stim.hex", "w", newline="\n") as f:
            for (rst, iv, rs, s) in cyc:
                f.write(f"{(rst << 18) | (iv << 17) | (rs << 16) | to_u16(s):05x}\n")
    for lat, fn in ((1, "gls_expected_lat1.hex"), (2, "gls_expected_lat2.hex")):
        exp = expected_lat1(cyc) if lat == 1 else expected_lat2(cyc)
        with open(build / fn, "w", newline="\n") as f:
            for (m, l, r, w, ov) in exp:
                word = (to_u16(m) << 57) | (l << 33) | (r << 17) | (w << 1) | ov
                f.write(f"{word:019x}\n")
    print(f"cycles={len(cyc)}")


if __name__ == "__main__":
    main()
