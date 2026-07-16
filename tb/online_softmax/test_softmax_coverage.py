"""online_softmax Phase 3: functional coverage model + constrained-random
stimulus, extending tb/online_softmax/ ONLY (per the build brief). Closes the
audit finding that no existing test approaches the DEN worst case: l reaches
only ~2^21 in tb/online_softmax/test_online_softmax.py's longest rows
(length <= 64), while a 256-element constant-score row hits l = 2^23 exactly,
exercising l bits [23:22] that plain line coverage cannot see.

This file does NOT re-derive the golden model: it imports SoftmaxMirror,
softmax_step, drive_and_check, start_and_reset and the model/attn.py helpers
directly from test_online_softmax (house style, same seeded_rng plumbing via
cocotb.RANDOM_SEED). Every stimulus element in this file is still checked
cycle-by-cycle against that SAME mirror (via drive_and_check); the coverage
model below only OBSERVES the values that check already computed, it does
not weaken or replace it.

Coverage model: plain Python dict-of-counters (no external coverage library,
cocotb-friendly). Bins are defined in COV.GROUPS below, one dict entry per
docs/uarch.md-derived corner (score value, diff_w, LUT index for both w and r
paths, rescale factor, l value, row length, control sequencing, and three
cross bins). See docs/uarch.md 3.5, 3.6, 6, 6.1, 8.2 for the equations that
motivate each bin.

Test order matters here (relied upon): cocotb 2.x's RegressionManager
discovers tests via vars(module).items(), an insertion-ordered dict, and
start_regression() does a STABLE sort by stage (all default stage 0), so
tests in one module run in file definition order. directed_den_worst_case is
defined first (adds its coverage hits, including the l >= 2^23 bins and the
identity-rescale-at-large-l cross bin), constrained_random_coverage is
defined second and, being last, dumps the aggregated report at its own end.
Both share the single module-level COV object, so the report reflects the
union of everything this file drove through the DUT.
"""

import pathlib
import sys

import cocotb
from cocotb.triggers import RisingEdge

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "model"))
import attn  # noqa: E402

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import test_online_softmax as tos  # noqa: E402

DEN_MOD = 1 << 24
REPORT_PATH = pathlib.Path(__file__).resolve().parent / "func_coverage.txt"


# ============================================================================
# Coverage model
# ============================================================================
class CoverageModel:
    """Plain-Python functional coverage: named bins per group, hit counts.
    Bin definitions transcribed directly from the build brief (docs/uarch.md
    3.3-3.6, 6, 6.1, 8.2 provide the underlying invariants each bin probes)."""

    GROUPS = {
        # s in {min -32768, [-32768,-16384), [-16384,0), 0, (0,16384),
        #       [16384, 32767], max 32767}
        "score": [
            "eq_min_-32768",
            "range_-32768_-16384",
            "range_-16384_0",
            "eq_zero",
            "range_0_16384",
            "range_16384_32767",
            "eq_max_32767",
        ],
        # diff_w = s - m_new (always <= 0 by construction: m_new = max(m_base, s))
        "diff_w": [
            "eq_zero",                      # this element IS the new max
            "positive_impossible",          # documented unreachable, see UNREACHABLE
            "small_negative_-1024_-16",      # value in [-1.0, -2^-6] (1..64 grid steps)
            "domain_interior",              # deeper in-domain, not at the clamp edge
            "clamp_edge_exact_-16384",       # diff == domain floor exactly (-16.0)
            "below_clamp",                  # diff < -16384, functional clamp engages
            "zero_tail_idx_ge_710",         # post-clamp/round idx lands in the LUT's zero tail
        ],
        "idx_w": ["0", "1", "2-63", "64-255", "256-511", "512-709", "710-1022", "1023"],
        "idx_r": ["0", "1", "2-63", "64-255", "256-511", "512-709", "710-1022", "1023"],
        "rescale": ["identity_0x8000", "genuine_0_to_0x8000", "zero"],
        "l_value": [
            "eq_0",
            "range_0_2p15",
            "range_2p15_2p21",
            "range_2p21_2p23",
            "eq_2p23",
            "bits23_22_nonzero",
        ],
        "row_length": ["len_1", "len_2", "len_3-16", "len_17-64", "len_65-255", "len_256"],
        "control": [
            "row_start_and_valid",
            "idle_gap_1",
            "idle_gap_2-10",
            "idle_gap_gt10",
            "back_to_back_rows",
        ],
        "cross": [
            "max_updated_x_zero_tail_w",
            "identity_r_x_l_gt_2p21",
            "clamp_edge_x_rowlen_256",
        ],
    }

    # Bins that are structurally impossible to hit, with the reason. These are
    # excluded from the "reachable" denominator when computing closure %, and
    # listed explicitly in the report instead of being silently ignored.
    UNREACHABLE = {
        ("diff_w", "positive_impossible"): (
            "diff_w = s - m_new can never be > 0: m_new = max(m_base, s) by "
            "construction (docs/uarch.md section 6), so s <= m_new always "
            "and diff_w <= 0 for every accepted element. Asserted structurally "
            "(never attempted), and also asserted directly in the RTL FORMAL "
            "block (rtl/online_softmax.sv: assert (diff_s <= 17'sd0);)."
        ),
    }

    def __init__(self):
        self.hits = {g: {n: 0 for n in names} for g, names in self.GROUPS.items()}

    def hit(self, group, name):
        self.hits[group][name] += 1

    def report(self):
        lines = []
        total_bins = 0
        total_hit = 0
        total_reachable = 0
        total_reachable_hit = 0
        for group, names in self.GROUPS.items():
            g_total = len(names)
            g_hit = sum(1 for n in names if self.hits[group][n] > 0)
            g_reachable = sum(1 for n in names if (group, n) not in self.UNREACHABLE)
            g_reachable_hit = sum(
                1
                for n in names
                if (group, n) not in self.UNREACHABLE and self.hits[group][n] > 0
            )
            total_bins += g_total
            total_hit += g_hit
            total_reachable += g_reachable
            total_reachable_hit += g_reachable_hit
            pct = 100.0 * g_reachable_hit / g_reachable if g_reachable else 100.0
            lines.append(f"[{group}] {g_reachable_hit}/{g_reachable} reachable bins hit "
                         f"({pct:.1f}%), {g_total - g_reachable} documented-unreachable")
            for n in names:
                c = self.hits[group][n]
                tag = "UNREACHABLE" if (group, n) in self.UNREACHABLE else ("HIT" if c else "MISS")
                lines.append(f"    {tag:11s} {group}.{n:28s} hits={c}")
        overall_pct = 100.0 * total_reachable_hit / total_reachable if total_reachable else 100.0
        header = [
            "online_softmax functional coverage report",
            "seed: %s" % getattr(cocotb, "RANDOM_SEED", "?"),
            f"TOTAL: {total_reachable_hit}/{total_reachable} reachable bins hit "
            f"({overall_pct:.1f}%), {total_bins - total_reachable} documented-unreachable, "
            f"{total_bins} bins defined",
            "",
        ]
        unreachable_lines = ["", "Documented-unreachable bins and reasons:"]
        for (group, name), reason in self.UNREACHABLE.items():
            unreachable_lines.append(f"  {group}.{name}: {reason}")
        missed = [
            f"  {group}.{n}"
            for group, names in self.GROUPS.items()
            for n in names
            if (group, n) not in self.UNREACHABLE and self.hits[group][n] == 0
        ]
        miss_lines = ["", "Unhit reachable bins (coverage gap, should be empty at closure):"]
        miss_lines += missed if missed else ["  (none)"]
        text = "\n".join(header + lines + unreachable_lines + miss_lines) + "\n"
        return text, overall_pct, missed


COV = CoverageModel()


# ============================================================================
# Bin classifiers
# ============================================================================
def classify_score(s):
    if s == -32768:
        COV.hit("score", "eq_min_-32768")
    if -32768 <= s < -16384:
        COV.hit("score", "range_-32768_-16384")
    if -16384 <= s < 0:
        COV.hit("score", "range_-16384_0")
    if s == 0:
        COV.hit("score", "eq_zero")
    if 0 < s < 16384:
        COV.hit("score", "range_0_16384")
    if 16384 <= s <= 32767:
        COV.hit("score", "range_16384_32767")
    if s == 32767:
        COV.hit("score", "eq_max_32767")


def classify_diff_w(diff_s, idx_w):
    """diff_s is the PRE-clamp raw difference s - m_new (may be < -16384)."""
    if diff_s == 0:
        COV.hit("diff_w", "eq_zero")
    elif diff_s > 0:
        COV.hit("diff_w", "positive_impossible")  # never actually reached
    elif -1024 <= diff_s <= -16:
        COV.hit("diff_w", "small_negative_-1024_-16")
    elif -16383 <= diff_s < -1024:
        COV.hit("diff_w", "domain_interior")
    if diff_s == -16384:
        COV.hit("diff_w", "clamp_edge_exact_-16384")
    if diff_s < -16384:
        COV.hit("diff_w", "below_clamp")
    if idx_w >= 710:
        COV.hit("diff_w", "zero_tail_idx_ge_710")


def idx_bin_name(idx):
    if idx == 0:
        return "0"
    if idx == 1:
        return "1"
    if 2 <= idx <= 63:
        return "2-63"
    if 64 <= idx <= 255:
        return "64-255"
    if 256 <= idx <= 511:
        return "256-511"
    if 512 <= idx <= 709:
        return "512-709"
    if 710 <= idx <= 1022:
        return "710-1022"
    if idx == 1023:
        return "1023"
    raise AssertionError(f"idx {idx} outside [0, 1023]")


def classify_rescale(r):
    if r == 0x8000:
        COV.hit("rescale", "identity_0x8000")
    elif 0 < r < 0x8000:
        COV.hit("rescale", "genuine_0_to_0x8000")
    if r == 0:
        COV.hit("rescale", "zero")


def classify_l(l):
    if l == 0:
        COV.hit("l_value", "eq_0")
    elif 0 < l <= (1 << 15):
        COV.hit("l_value", "range_0_2p15")
    elif (1 << 15) < l <= (1 << 21):
        COV.hit("l_value", "range_2p15_2p21")
    elif (1 << 21) < l < (1 << 23):
        COV.hit("l_value", "range_2p21_2p23")
    if l == (1 << 23):
        COV.hit("l_value", "eq_2p23")
    if (l >> 22) & 0x3:
        COV.hit("l_value", "bits23_22_nonzero")


def row_length_bin_name(rlen):
    if rlen == 1:
        return "len_1"
    if rlen == 2:
        return "len_2"
    if 3 <= rlen <= 16:
        return "len_3-16"
    if 17 <= rlen <= 64:
        return "len_17-64"
    if 65 <= rlen <= 255:
        return "len_65-255"
    if rlen == 256:
        return "len_256"
    return None


def idle_gap_bin_name(gap):
    if gap == 1:
        return "idle_gap_1"
    if 2 <= gap <= 10:
        return "idle_gap_2-10"
    if gap > 10:
        return "idle_gap_gt10"
    return None


# ============================================================================
# Row/gap tracker + the single coverage-aware drive step, shared by both tests
# ============================================================================
class RowTracker:
    def __init__(self):
        self.row_len = 0
        self.have_row = False
        self.any_max_update = False
        self.clamp_edge_seen = False
        self.gap_len = 0

    def finish_row_if_any(self):
        if self.have_row:
            name = row_length_bin_name(self.row_len)
            if name:
                COV.hit("row_length", name)


async def cov_step(dut, mirror, tracker, in_valid, row_start, s, msg):
    """One cycle: drives+checks (dut vs mirror, via test_online_softmax's own
    drive_and_check -- the self-checking core is NOT duplicated here), then
    records every coverage bin this cycle can speak to."""
    if in_valid:
        m_base = tos.M_INIT if row_start else mirror.m
        m_new = m_base if m_base >= s else s
        diff_m = m_base - m_new
        diff_s = s - m_new
        idx_r = attn.lut_index(diff_m)
        idx_w = attn.lut_index(diff_s)
        max_updated = m_new > m_base
        assert diff_m <= 0 and diff_s <= 0, "invariant: diffs must be <= 0"

        if row_start:
            if tracker.have_row and tracker.gap_len == 0:
                COV.hit("control", "back_to_back_rows")
            tracker.finish_row_if_any()
            tracker.row_len = 0
            tracker.any_max_update = False
            tracker.clamp_edge_seen = False
            tracker.have_row = True

        COV.hit("control", "row_start_and_valid")
        classify_score(s)
        classify_diff_w(diff_s, idx_w)
        COV.hit("idx_w", idx_bin_name(idx_w))
        COV.hit("idx_r", idx_bin_name(idx_r))

        if tracker.any_max_update and idx_w >= 710:
            COV.hit("cross", "max_updated_x_zero_tail_w")
        if diff_s == -16384:
            tracker.clamp_edge_seen = True

        tracker.row_len += 1
        if max_updated:
            tracker.any_max_update = True

        if tracker.gap_len > 0:
            gb = idle_gap_bin_name(tracker.gap_len)
            if gb:
                COV.hit("control", gb)
        tracker.gap_len = 0
    else:
        tracker.gap_len += 1

    await tos.drive_and_check(dut, mirror, in_valid, row_start, s, msg)

    # l and rescale are continuously-visible/registered outputs (docs/uarch.md
    # 8.2 port table); sample every cycle, not just accepted ones, so idle
    # holds (including the post-reset l == 0 hold before any row) count too.
    classify_l(mirror.l)
    classify_rescale(mirror.r)
    if mirror.r == 0x8000 and mirror.l > (1 << 21):
        COV.hit("cross", "identity_r_x_l_gt_2p21")
    if in_valid and tracker.clamp_edge_seen and tracker.row_len >= 256:
        COV.hit("cross", "clamp_edge_x_rowlen_256")


# ============================================================================
# Directed DEN worst case (audit finding): 256-element constant-score row.
# ============================================================================
@cocotb.test()
async def directed_den_worst_case(dut):
    """The audit finding this session must close: no existing test approaches
    the DEN worst case (l reaches only ~2^21 with row length <= 64). A
    256-element row of IDENTICAL scores never moves the running max after
    element 0 (uarch.md 6.1 identity 1: r == 0x8000 exact identity), so every
    step is w = 0x8000, r = 0x8000 (after element 0), and
    l_{j+1} = l_j + 32768 exactly (rshr(l*32768,15) == l for any l, per the
    identity-1 proof): l after j elements (1-indexed, j = 1..256) ==
    j * 2^15 exactly, reaching l == 256 * 32768 == 2^23 at j == 256
    (N_MAX == 256, uarch.md 8.2's induction premise N <= 256 is respected).
    Asserts EXACT equality every step (not just at the end), plus the mirror
    DEN width bound 0 <= l < 2^24 throughout (uarch.md 3.6)."""
    await tos.start_and_reset(dut)
    mirror = tos.SoftmaxMirror()
    mirror.reset()
    tracker = RowTracker()

    # l == 0 is visible right after reset, before any row starts (continuously
    # visible per docs/uarch.md 8.2's port table); sample it explicitly so the
    # l_value.eq_0 bin does not depend on timing of the first row elsewhere.
    classify_l(mirror.l)

    CONST_SCORE = 12345  # arbitrary; identity holds for ANY constant score
    N = 256
    for j in range(N):
        await cov_step(
            dut, mirror, tracker, True, j == 0, CONST_SCORE, f"den-worst j={j}"
        )
        expected_l = (j + 1) * (1 << 15)
        assert 0 <= mirror.l < DEN_MOD, (
            f"j={j}: DEN width bound violated: l={mirror.l}"
        )
        assert mirror.l == expected_l, (
            f"j={j}: l={mirror.l} != exact induction bound {expected_l} "
            f"(uarch.md 3.6 identity-1 chain)"
        )
        assert int(dut.l.value) == expected_l, (
            f"j={j}: rtl l={int(dut.l.value)} != exact {expected_l}"
        )
        if j > 0:
            assert int(dut.r.value) == 0x8000, (
                f"j={j}: r={int(dut.r.value):#x} != identity 0x8000"
            )
        assert int(dut.w.value) == 0x8000, f"j={j}: w != 0x8000 (identity 2)"

    assert mirror.l == (1 << 23), f"final l={mirror.l} != 2^23 exactly"
    assert (mirror.l >> 22) & 0x3, "l bits [23:22] must be nonzero at l == 2^23"
    tracker.finish_row_if_any()


# ============================================================================
# Directed probes: exact LUT index / diff_w edges, row lengths, control gaps,
# cross bins that constrained-random alone is very unlikely to hit exactly
# (needle-in-a-haystack exact boundary values), followed by a weighted
# constrained-random loop for general confidence. All still checked
# cycle-by-cycle against the SAME mirror via cov_step -> drive_and_check.
# ============================================================================
# Chosen so that -16*idx gives EXACTLY idx after the round-half-up index
# math (attn.lut_index / rtl lut_index_pre), same technique
# test_online_softmax.py's rom_lookup_spot_checks uses. These also hit every
# reachable diff_w bin (see docstring below for the mapping).
IDX_PROBE_DIFFS = [0, -16, -500, -1024, -1040, -5000, -8200, -11360, -16368, -16384, -20000]


async def probe_idx_w_and_diff_w(dut, mirror, tracker):
    """One 2-element row per diff target: row_start establishes m = BASE
    (BASE chosen with margin on both sides for |diff| up to 20000), then one
    non-updating element at s = BASE + diff exercises exactly that diff_w /
    idx_w pair. Diff list chosen to cover every idx_w range bin
    (0,1,2-63,64-255,256-511,512-709,710-1022,1023) and every reachable
    diff_w bin (eq_zero, small_negative, domain_interior, clamp_edge_exact,
    below_clamp, zero_tail) -- see the diff values picked above."""
    BASE = 10000
    for diff in IDX_PROBE_DIFFS:
        s0 = BASE
        s1 = BASE + diff
        assert -32768 <= s1 <= 32767
        await cov_step(dut, mirror, tracker, True, True, s0, f"idxw-probe base diff={diff}")
        await cov_step(dut, mirror, tracker, True, False, s1, f"idxw-probe elem diff={diff}")


async def probe_idx_r(dut, mirror, tracker):
    """One 2-element row per diff target: row_start establishes m = B, then a
    genuine UPDATE (s1 = B - diff, diff <= 0 so s1 >= B) makes
    diff_m = B - s1 = diff exactly, exercising that idx_r bin. (The update
    element's own diff_w is always 0 here, by identity: it becomes the new
    max; that is fine, diff_w bins are probed separately above.)"""
    B = -10000
    for diff in IDX_PROBE_DIFFS:
        s0 = B
        s1 = B - diff
        assert -32768 <= s1 <= 32767
        await cov_step(dut, mirror, tracker, True, True, s0, f"idxr-probe base diff={diff}")
        await cov_step(dut, mirror, tracker, True, False, s1, f"idxr-probe elem diff={diff}")


async def probe_score_extremes(dut, mirror, tracker):
    for s0 in (32767, -32768):
        await cov_step(dut, mirror, tracker, True, True, s0, f"score-extreme s0={s0}")


async def probe_row_lengths(dut, mirror, tracker, lengths):
    """Constant-score rows of the given lengths, back to back with no gap
    between them here (idle-gap and back-to-back bins are probed separately
    with explicit gaps, see probe_control_gaps)."""
    for length in lengths:
        for i in range(length):
            await cov_step(dut, mirror, tracker, True, i == 0, 777, f"rowlen={length} i={i}")


async def probe_control_gaps(dut, mirror, tracker):
    """Explicit idle gaps of length 1, 2-10 (5), >10 (15), each followed by a
    fresh row; then two rows back to back (gap == 0) for back_to_back_rows."""
    for gap in (1, 5, 15):
        for _ in range(gap):
            await cov_step(dut, mirror, tracker, False, False, 0, f"idle-gap len={gap}")
        await cov_step(dut, mirror, tracker, True, True, 1, f"post-gap({gap}) row-start")
        await cov_step(dut, mirror, tracker, True, False, 0, f"post-gap({gap}) elem2")
    # Back to back: no idle cycle between the previous row's last element and
    # this row_start.
    await cov_step(dut, mirror, tracker, True, True, 2, "back-to-back row A")
    await cov_step(dut, mirror, tracker, True, True, 3, "back-to-back row B (no gap)")


async def probe_cross_max_updated_zero_tail(dut, mirror, tracker):
    """max_updated_x_zero_tail_w: a max update early in the row, then (later
    in the SAME row) an element whose diff_w lands deep in the zero tail."""
    await cov_step(dut, mirror, tracker, True, True, 0, "cross-mzt row start (m=0)")
    await cov_step(dut, mirror, tracker, True, False, 20000, "cross-mzt update (m=20000)")
    await cov_step(dut, mirror, tracker, True, False, 0, "cross-mzt zero-tail elem (diff=-20000)")


async def probe_cross_clamp_edge_rowlen256(dut, mirror, tracker):
    """clamp_edge_x_rowlen_256: hit the clamp-edge diff_w exactly once early
    in a row, then pad the SAME row out to the full 256-element length with
    elements at the established max (identity holds, m never moves again)."""
    BASE = 10000
    await cov_step(dut, mirror, tracker, True, True, BASE, "cross-clamp256 row start")
    await cov_step(
        dut, mirror, tracker, True, False, BASE - 16384, "cross-clamp256 clamp-edge elem"
    )
    for i in range(254):
        await cov_step(dut, mirror, tracker, True, False, BASE, f"cross-clamp256 pad i={i}")
    assert tracker.row_len == 256


# ---- Constrained-random generator -------------------------------------------
def gen_row_scores(rng, length, mode, base):
    """Build `length` SCORE values for one row, shaped by `mode` (weighted
    choice made by the caller)."""
    scores = []
    m = tos.M_INIT
    for i in range(length):
        if mode == "constant":
            s = base
        elif mode == "increasing":
            s = base + 300 * i
        elif mode == "decreasing":
            s = base - 300 * i
        elif mode == "near_clamp_walk":
            # Occasionally drop close to (or past) 16.0 below the running max,
            # to bias toward the domain-clamp / zero-tail corners; otherwise a
            # small, non-updating wobble.
            cur_m = m if i > 0 else tos.M_INIT
            if i > 0 and rng.random() < 0.3:
                delta = -rng.choice([16384, 16368, 11360, 20000, 5000])
                s = cur_m + delta
            elif i == 0:
                s = base
            else:
                s = cur_m - rng.randint(0, 200)
        else:  # random_uniform
            s = rng.randint(-32768, 32767)
        s = max(-32768, min(32767, s))
        scores.append(s)
        m = s if (i == 0 or s > m) else m
    return scores


@cocotb.test()
async def constrained_random_coverage(dut):
    """Directed edge probes (deterministic, needed because several bins are
    exact-value needles that pure randomness is very unlikely to hit inside a
    runtime-bounded test: LUT index boundaries, the -16384 clamp edge, l
    value boundaries, exact idle-gap lengths, back-to-back rows, and the
    three cross bins), followed by a weighted constrained-random loop (long
    constant rows for the DEN corner, increasing/decreasing bursts, a near-
    clamp random walk, and plain uniform rows), all seeded from
    cocotb.RANDOM_SEED (house style, tb/matmul_tile and test_online_softmax's
    seeded_rng()). Dumps the aggregated coverage report (this test runs last
    in file-definition order, see module docstring) and asserts closure: every
    reachable bin must be hit, or the test fails loudly (house rule: no
    weakening a check to make it pass)."""
    await tos.start_and_reset(dut)
    mirror = tos.SoftmaxMirror()
    mirror.reset()
    tracker = RowTracker()
    rng = tos.seeded_rng()

    # ---- Directed probes (deterministic edge-hitting) ----------------------
    await probe_idx_w_and_diff_w(dut, mirror, tracker)
    await probe_idx_r(dut, mirror, tracker)
    await probe_score_extremes(dut, mirror, tracker)
    await probe_row_lengths(dut, mirror, tracker, [1, 2, 10, 40, 100])
    await probe_control_gaps(dut, mirror, tracker)
    await probe_cross_max_updated_zero_tail(dut, mirror, tracker)
    await probe_cross_clamp_edge_rowlen256(dut, mirror, tracker)

    # ---- Weighted constrained-random loop -----------------------------------
    modes = ["constant", "increasing", "decreasing", "near_clamp_walk", "random_uniform"]
    weights = [0.30, 0.15, 0.15, 0.25, 0.15]  # bias toward the DEN/clamp corners
    length_bins = [(1, 1), (2, 2), (3, 16), (17, 64), (65, 255), (256, 256)]
    length_weights = [0.10, 0.10, 0.20, 0.25, 0.20, 0.15]

    NUM_ROWS = 40
    for trial in range(NUM_ROWS):
        mode = rng.choices(modes, weights=weights, k=1)[0]
        lo, hi = rng.choices(length_bins, weights=length_weights, k=1)[0]
        length = rng.randint(lo, hi)
        base = rng.randint(-8000, 8000)
        scores = gen_row_scores(rng, length, mode, base)

        # Occasional idle gap before the row (not on trial 0, so at least one
        # back-to-back transition is also possible via random chance on top
        # of the deterministic probe_control_gaps coverage above).
        if trial > 0 and rng.random() < 0.5:
            for _ in range(rng.randint(1, 4)):
                await cov_step(dut, mirror, tracker, False, False, 0, f"cr trial{trial} idle")

        for i, s in enumerate(scores):
            if i > 0 and rng.random() < 0.05:
                await cov_step(dut, mirror, tracker, False, False, 0, f"cr trial{trial} mid-idle")
            await cov_step(dut, mirror, tracker, True, i == 0, s, f"cr trial{trial} elem{i}")

    tracker.finish_row_if_any()

    # ---- Dump report + assert closure ---------------------------------------
    text, pct, missed = COV.report()
    REPORT_PATH.write_text(text)
    cocotb.log.info("\n" + text)
    assert not missed, (
        f"functional coverage NOT closed: {len(missed)} reachable bin(s) unhit: "
        f"{missed}. See {REPORT_PATH}"
    )
    assert pct == 100.0, f"coverage {pct:.1f}% != 100% of reachable bins"
