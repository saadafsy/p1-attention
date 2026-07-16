"""online_softmax testbench: checks the RTL per-row online-softmax (m, l)
state machine against the golden-model recurrence (docs/uarch.md 8.2, the
exact equations of section 6, built directly from model/attn.py's
lut_index/rshr/gen_exp_lut -- those ARE the golden reference, not
re-derived here).

ROM equivalence is checked TWICE, at two different levels of the flow:
  1. A pure-Python, non-simulation check (rtl/exp_lut.svh vs
     model/exp_lut.hex vs model/attn.py's gen_exp_lut(), plus the
     docs/uarch.md 3.5 sha256 pin) executed at TB import time, so a wrong
     .svh fails before any simulation even starts.
  2. In-sim spot checks of w against lut[idx] at chosen indices, proving
     the RTL's own combinational ROM (not just the two source files)
     produces the right value end to end.

Mirror model: SoftmaxMirror below reproduces the RTL bit for bit, including
the row_start basis override and the "hold when !in_valid" behavior (w, r,
m, l all hold their previous register value, out_valid drops), matching
the cycle diagram in docs/uarch.md 8.2. The DEN width bound
0 <= l < 2^24 (uarch.md 3.6) is asserted on every mirror step, not just at
the end of a row.

Drive on RisingEdge, sample on FallingEdge (post-NBA, stable), same house
style as tb/matmul_tile/test_matmul_tile.py. Seed plumbing: every RNG is
built from cocotb.RANDOM_SEED via seeded_rng(), so SEED=1 vs SEED=7
provably changes stimulus (same pattern as tb/matmul_tile).
"""

import hashlib
import pathlib
import random
import re
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

# ---- Import the golden model directly (repo-root relative) ----------------
ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "model"))
import attn  # noqa: E402

LUT = attn.gen_exp_lut()
HEX_PATH = ROOT / "model" / "exp_lut.hex"
SVH_PATH = ROOT / "rtl" / "exp_lut.svh"
PINNED_SHA256 = (
    "541676bde3a2a703ec0e021960eed77a1806f6182cd4a8d48803e57302e84ba5"
)

M_INIT = attn.M_INIT
EXP_ONE = attn.EXP_ONE
DEN_MOD = 1 << 24


# ---- ROM equivalence: non-simulation check, run at TB import time ---------
def _parse_hex(path):
    vals = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            vals.append(int(line, 16))
    return vals


def _parse_svh(path):
    text = path.read_text()
    entries = {}
    for m in re.finditer(
        r"10'd(\d+):\s*exp_lut_rom\s*=\s*16'h([0-9a-fA-F]{4});", text
    ):
        entries[int(m.group(1))] = int(m.group(2), 16)
    assert len(entries) == 1024, (
        f"rtl/exp_lut.svh: parsed {len(entries)} case entries, expected 1024"
    )
    return [entries[j] for j in range(1024)]


def _check_rom_sources():
    hex_lut = _parse_hex(HEX_PATH)
    svh_lut = _parse_svh(SVH_PATH)
    assert len(hex_lut) == 1024, (
        f"model/exp_lut.hex has {len(hex_lut)} entries, expected 1024"
    )
    assert hex_lut == svh_lut, (
        "model/exp_lut.hex and rtl/exp_lut.svh diverge entry-for-entry "
        "(as-built RTL ROM does not match the normative table)"
    )
    assert hex_lut == LUT, (
        "model/exp_lut.hex diverges from model/attn.py gen_exp_lut()"
    )
    digest = hashlib.sha256(HEX_PATH.read_bytes()).hexdigest()
    assert digest == PINNED_SHA256, (
        f"model/exp_lut.hex sha256 {digest} != pinned {PINNED_SHA256} "
        "(docs/uarch.md 3.5)"
    )


_check_rom_sources()  # executed at import/collection time, before any sim


# ---- Bit-width helpers ------------------------------------------------------
def wrap_signed(x, bits):
    mod = 1 << bits
    x &= mod - 1
    if x >= (mod >> 1):
        x -= mod
    return x


def wrap16(x):
    return wrap_signed(x, 16)


def seeded_rng():
    """Build an RNG from cocotb's per-test seed (house style, see
    tb/matmul_tile/test_matmul_tile.py docstring for the full rationale)."""
    seed = getattr(cocotb, "RANDOM_SEED", None)
    if seed is None:
        seed = 1  # defensive fallback only; COCOTB_RANDOM_SEED is always set
    return random.Random(seed)


# ---- Golden step function, built directly from model/attn.py --------------
def softmax_step(m, l, s, row_start):
    """One step of docs/uarch.md section 6 / 8.2, built directly from
    model/attn.py's lut_index/rshr/gen_exp_lut. Returns (m_new, l_new, w, r).
    Asserts the DEN width bound (uarch.md 3.6) on every call."""
    m_base = M_INIT if row_start else m
    l_base = 0 if row_start else l
    m_new = m_base if m_base >= s else s
    diff_m = m_base - m_new
    diff_s = s - m_new
    r = LUT[attn.lut_index(diff_m)]
    w = LUT[attn.lut_index(diff_s)]
    l_new = attn.rshr(l_base * r, attn.W_FRAC) + w
    assert 0 <= l_new < DEN_MOD, f"DEN width violated: l={l_new}"
    return m_new, l_new, w, r


class SoftmaxMirror:
    """Bit-exact software mirror of the RTL registers (m, l, w, r,
    out_valid), including the hold-on-!in_valid behavior."""

    def reset(self):
        self.m = M_INIT
        self.l = 0
        self.w = 0
        self.r = 0
        self.out_valid = False

    def step(self, in_valid, row_start, s):
        if in_valid:
            self.m, self.l, self.w, self.r = softmax_step(
                self.m, self.l, s, row_start
            )
        self.out_valid = bool(in_valid)


# ---- DUT drive/check helpers ------------------------------------------------
async def start_and_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.in_valid.value = 0
    dut.row_start.value = 0
    dut.s.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def check_outputs(dut, mirror, msg):
    got_m = wrap16(int(dut.m.value))
    got_l = int(dut.l.value)
    got_w = int(dut.w.value)
    got_r = int(dut.r.value)
    got_ov = bool(dut.out_valid.value)
    assert got_m == mirror.m, f"{msg}: m rtl={got_m} mirror={mirror.m}"
    assert got_l == mirror.l, f"{msg}: l rtl={got_l} mirror={mirror.l}"
    assert got_w == mirror.w, f"{msg}: w rtl={got_w} mirror={mirror.w}"
    assert got_r == mirror.r, f"{msg}: r rtl={got_r} mirror={mirror.r}"
    assert got_ov == mirror.out_valid, (
        f"{msg}: out_valid rtl={got_ov} mirror={mirror.out_valid}"
    )
    assert 0 <= mirror.l < DEN_MOD, f"{msg}: DEN width bound violated: l={mirror.l}"


async def drive_and_check(dut, mirror, in_valid, row_start, s, msg):
    dut.in_valid.value = int(bool(in_valid))
    dut.row_start.value = int(bool(row_start))
    dut.s.value = s
    await RisingEdge(dut.clk)
    mirror.step(bool(in_valid), bool(row_start), s)
    await FallingEdge(dut.clk)
    check_outputs(dut, mirror, msg)


# ---- Tests -------------------------------------------------------------------
@cocotb.test()
async def reset_and_first_element_identity(dut):
    """After rst: m == -32768, l == 0, out_valid == 0 (section 6 init).
    First accepted element of a row (identity 2, uarch.md 6.1): m == s0 and
    l == 32768 and w == lut[0] == 32768 ALWAYS (independent of s0, since
    diff_s = s0 - m_new = 0 exactly); r is checked against the mirror
    rather than hand-assumed, since it is 0 only when the (m_base - s0)
    clamp saturates the LUT's zero tail, which the mirror computes, not
    guesses."""
    await start_and_reset(dut)
    mirror = SoftmaxMirror()
    mirror.reset()
    await FallingEdge(dut.clk)
    check_outputs(dut, mirror, "post-reset")

    for s0 in (0, 1, -1, 32767, -32768, -16384, 16384, -100, 12345):
        row_mirror = SoftmaxMirror()
        row_mirror.reset()
        await drive_and_check(dut, row_mirror, True, True, s0, f"first-elem s0={s0}")
        assert row_mirror.m == s0, f"s0={s0}: identity-2 m {row_mirror.m} != s0"
        assert row_mirror.l == EXP_ONE, f"s0={s0}: identity-2 l {row_mirror.l} != 32768"
        assert row_mirror.w == EXP_ONE, f"s0={s0}: identity-2 w {row_mirror.w} != 32768"


@cocotb.test()
async def rom_lookup_spot_checks(dut):
    """In-sim spot checks of the RTL's own combinational ROM: establish a
    known running max (m = 0 via row_start), then drive scores that hit
    exact LUT indices 0, 1, 64, 128, 256, 443, 512, 709, 710, 1023 (the
    docs/uarch.md 3.5 anchor entries plus the zero-tail boundary), checking
    w against lut[idx] exactly every time."""
    await start_and_reset(dut)
    mirror = SoftmaxMirror()
    mirror.reset()

    # Establish m = 0, l = 32768 via row_start with s0 = 0.
    await drive_and_check(dut, mirror, True, True, 0, "spot-check row start (m=0)")
    assert mirror.m == 0

    targets = [0, 1, 64, 128, 256, 443, 512, 709, 710, 1023]
    for idx in targets:
        diff = -16 * idx  # nd = 16*idx -> idx_pre = (16*idx+8)>>4 = idx exactly
        computed_idx = attn.lut_index(diff)
        assert computed_idx == idx, (
            f"index math self-check: lut_index({diff}) = {computed_idx} != {idx}"
        )
        s = mirror.m + diff  # mirror.m stays 0 throughout (diff <= 0 always)
        await drive_and_check(dut, mirror, True, False, s, f"spot-check idx={idx}")
        assert mirror.m == 0, "spot-check setup error: m must not move"
        assert int(dut.w.value) == LUT[idx], (
            f"idx {idx}: rtl w={int(dut.w.value)} != lut[{idx}]={LUT[idx]}"
        )
        assert mirror.w == LUT[idx]


@cocotb.test()
async def rom_full_sweep(dut):
    """Exhaustive sweep of all 1024 possible LUT indices, i.e. every case
    arm of the generated exp_lut_rom (rtl/exp_lut.svh), checking w against
    lut[idx] exactly at each one. Added because verilator --coverage-line
    instruments each of the 1024 generated case-assignment lines as a
    separate coverage point: the 10-point spot check above leaves 1014 of
    them formally unexercised, which is a real coverage gap (found by
    running scripts/check_coverage.py: 85.3% line coverage, all 156
    zero-hit points inside exp_lut.svh), not a cosmetic one. This test
    closes it without weakening any check elsewhere."""
    await start_and_reset(dut)
    mirror = SoftmaxMirror()
    mirror.reset()
    await drive_and_check(dut, mirror, True, True, 0, "sweep row start (m=0)")
    for idx in range(1024):
        diff = -16 * idx
        s = mirror.m + diff  # mirror.m stays 0 throughout (diff <= 0 always)
        await drive_and_check(dut, mirror, True, False, s, f"sweep idx={idx}")
        assert int(dut.w.value) == LUT[idx], (
            f"sweep idx {idx}: rtl w={int(dut.w.value)} != lut[{idx}]={LUT[idx]}"
        )


@cocotb.test()
async def directed_sequences(dut):
    """Strictly increasing (genuine rescale every step), strictly
    decreasing (r stays the exact identity 0x8000, l == sum of w's),
    constant score, domain clamp (diff < -16384), and SCORE extremes."""
    await start_and_reset(dut)

    # Strictly increasing: max updates every step, real rescale (r < 0x8000)
    # every step after the first.
    mirror = SoftmaxMirror()
    mirror.reset()
    scores = [-20000 + 200 * i for i in range(40)]
    for i, s in enumerate(scores):
        await drive_and_check(dut, mirror, True, i == 0, s, f"increasing[{i}]")
        if i > 0:
            assert int(dut.r.value) != 0x8000, (
                f"increasing[{i}]: expected a genuine rescale (r != 0x8000)"
            )

    # Strictly decreasing: after the first element sets the max, every
    # later step keeps r == 0x8000 exactly (identity 1, uarch.md 6.1); l
    # must equal the exact sum of all w's with zero drift.
    mirror = SoftmaxMirror()
    mirror.reset()
    scores = [20000 - 300 * i for i in range(40)]
    w_sum = 0
    for i, s in enumerate(scores):
        await drive_and_check(dut, mirror, True, i == 0, s, f"decreasing[{i}]")
        w_sum += mirror.w
        if i > 0:
            assert int(dut.r.value) == 0x8000, (
                f"decreasing[{i}]: r={int(dut.r.value):#x} != 0x8000 (identity 1)"
            )
    assert mirror.l == w_sum, f"identity-1 check: l={mirror.l} != sum(w)={w_sum}"
    assert int(dut.l.value) == w_sum

    # Constant score: max set once, then identity holds every later step.
    mirror = SoftmaxMirror()
    mirror.reset()
    for i in range(20):
        await drive_and_check(dut, mirror, True, i == 0, 500, f"constant[{i}]")
        if i > 0:
            assert int(dut.r.value) == 0x8000, f"constant[{i}]: r != identity"

    # Domain clamp: diff well below -16384 (functional clamp, uarch.md 5).
    # s is driven far below the established max, so it is diff_s = s - m_new
    # (which feeds w, this element's own weight) that saturates the LUT zero
    # tail; diff_m = m_base - m_new stays 0 (m does not move), so r stays the
    # exact identity 0x8000, not the clamp value. Getting this pairing right
    # (w vs r) is the point of the earlier test-authoring bug this comment
    # documents: an initial version of this test asserted r == 0 here, which
    # failed because it clamped the wrong one of the two diffs.
    mirror = SoftmaxMirror()
    mirror.reset()
    await drive_and_check(dut, mirror, True, True, 32767, "clamp row-start (m=32767)")
    await drive_and_check(dut, mirror, True, False, -32768, "clamp: diff << -16384")
    assert int(dut.w.value) == 0, "clamp: w should hit the LUT zero tail"
    assert int(dut.r.value) == 0x8000, "clamp: r should stay identity (m did not move)"

    # SCORE extremes at row start (+/-32767, -32768).
    for s0 in (32767, -32768, -32767, 32766):
        mirror = SoftmaxMirror()
        mirror.reset()
        await drive_and_check(dut, mirror, True, True, s0, f"extreme row-start s0={s0}")


@cocotb.test()
async def full_row_golden_compare(dut):
    """100 random rows of length 1..64, SCORE-range values, idle gaps
    randomly interleaved, some rows back to back with no dead cycle.
    Compares (m, l, w, r, out_valid) every single cycle against the
    mirror, not just at row boundaries."""
    await start_and_reset(dut)
    mirror = SoftmaxMirror()
    mirror.reset()
    rng = seeded_rng()

    for trial in range(100):
        length = rng.randint(1, 64)
        scores = [rng.randint(-32768, 32767) for _ in range(length)]
        back_to_back = rng.random() < 0.5

        if trial > 0 and not back_to_back:
            for _ in range(rng.randint(1, 3)):
                await drive_and_check(
                    dut, mirror, False, False, 0, f"trial{trial} pre-row idle"
                )

        for i, s in enumerate(scores):
            if i > 0 and rng.random() < 0.3:
                for _ in range(rng.randint(1, 2)):
                    await drive_and_check(
                        dut, mirror, False, False, 0, f"trial{trial} mid-row idle"
                    )
            await drive_and_check(
                dut, mirror, True, i == 0, s, f"trial{trial} elem{i}"
            )


@cocotb.test()
async def realistic_flow_vs_attn_trace(dut):
    """2 random N=16 attention cases: real score streams via model/attn.py
    (sacc -> s per uarch.md 3.3, s = sat(rshr(sacc, 2+D_SHIFT), ...)), fed
    row by row; final l per row checked against attn_fixed's trace= hook
    (the same golden model that will gate attention_top later)."""
    await start_and_reset(dut)
    mirror = SoftmaxMirror()
    mirror.reset()
    rng = seeded_rng()
    n = 16
    d = attn.D_DIM

    for case in range(2):
        q = [[rng.randint(-128, 127) for _ in range(d)] for _ in range(n)]
        k = [[rng.randint(-128, 127) for _ in range(d)] for _ in range(n)]
        v = [[rng.randint(-128, 127) for _ in range(d)] for _ in range(n)]
        trace = []
        attn.attn_fixed(q, k, v, LUT, trace=trace)

        for i in range(n):
            row_trace = [t for t in trace if t[0] == i]
            assert len(row_trace) == n
            for j in range(n):
                sacc = sum(q[i][dd] * k[j][dd] for dd in range(d))
                s = attn.sat(
                    attn.rshr(sacc, 2 + attn.D_SHIFT), -32768, 32767
                )
                await drive_and_check(
                    dut, mirror, True, j == 0, s, f"case{case} row{i} elem{j}"
                )
            expected_l = row_trace[-1][3]
            assert int(dut.l.value) == expected_l, (
                f"case{case} row{i}: rtl l={int(dut.l.value)} != trace l={expected_l}"
            )
            assert mirror.l == expected_l


@cocotb.test()
async def random_control_fuzz(dut):
    """2000 cycles of fully random in_valid/row_start/s vs the mirror,
    checked every cycle, including that (m, l) hold exactly when
    in_valid == 0 and out_valid drops. Row length is capped (forced
    row_start) at 60 elements to stay well under the 256-row bound the
    DEN width proof relies on (uarch.md 3.6), per the house rule to keep
    row lengths <= 256 everywhere in this TB."""
    await start_and_reset(dut)
    mirror = SoftmaxMirror()
    mirror.reset()
    rng = seeded_rng()

    row_len = 0
    for cycle in range(2000):
        in_valid = rng.random() < 0.8
        row_start = rng.random() < 0.1
        if in_valid:
            if row_len >= 60:
                row_start = True
            row_len = 1 if row_start else row_len + 1
        s = rng.randint(-32768, 32767)
        await drive_and_check(dut, mirror, in_valid, row_start, s, f"fuzz cycle {cycle}")
