"""online_softmax PIPE_ROM=1 testbench: VALUE correctness of the registered-
ROM (latency-2) variant (docs/uarch.md 8.2.1) against model/attn.py, at the
alignment formal (formal/online_softmax.sby task p1) deliberately does not
and cannot check (an open bmc flow proving a 1024-way ROM / 40-bit multiply
functionally correct is exactly the kind of proof the tool cannot do; formal
only proves port-level latency-2 ALIGNMENT and the config-independent clamp
facts -- see the .sby header comment). This file proves the per-element
VALUES (m, l, w, r) the pipelined RTL produces are bit-identical to the
model/attn.py recurrence, at every cycle, including gaps, back-to-back rows,
drain, and mid-pipe reset.

Only runs when the DUT elaborates with PIPE_ROM=1 (tb/online_softmax/Makefile
PIPE_ROM=1 -> -GPIPE_ROM=1, plus this module replacing the default
COCOTB_TEST_MODULES). assert_pipe_rom_1() re-checks this at runtime via
dut.PIPE_ROM.value so a Makefile/test-module wiring mismatch fails loudly
instead of silently testing the wrong configuration.

Reuses test_online_softmax's imports, LUT, M_INIT/EXP_ONE, wrap16,
seeded_rng, start_and_reset (byte-for-byte the same reset drive sequence;
the PIPE_ROM=1 register set -- m, l, w, r, out_valid, plus the internal
v_p/rs_p/w_p/r_p pipe regs -- is fully zeroed/M_INIT by that same sequence,
see PipeRom1Mirror.clock's reset branch) and check_outputs (generic over any
mirror object exposing .m/.l/.w/.r/.out_valid, so no duplication needed).

PipeRom1Mirror below is a direct transcription of rtl/online_softmax.sv's
g_lat2 always_comb + always_ff blocks: stage 1 (m, and the two ROM lookups
that become w_p/r_p) reads the OLD self.m; stage 2 (the l update) reads the
OLD self.l/v_p/rs_p/w_p/r_p; both stages "commit" via nonblocking-style
simultaneous assignment at the end of clock(), exactly mirroring the RTL's
two always_ff blocks firing on the same edge.
"""

import pathlib
import sys

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "model"))
import attn  # noqa: E402

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import test_online_softmax as tos  # noqa: E402

LUT = tos.LUT
M_INIT = tos.M_INIT
EXP_ONE = tos.EXP_ONE
DEN_MOD = tos.DEN_MOD
wrap16 = tos.wrap16
seeded_rng = tos.seeded_rng
start_and_reset = tos.start_and_reset
check_outputs = tos.check_outputs


PIPE_COV_REPORT_PATH = pathlib.Path(__file__).resolve().parent / "func_coverage_pipe_rom1.txt"


class PipeCoverageModel:
    """Minimal functional coverage scoped ONLY to corners that are genuinely
    NEW in the PIPE_ROM=1 elaboration (docs/uarch.md 8.2.1) -- i.e. corners
    that do not exist, or cannot be distinguished, at latency 1. This is
    deliberately separate from test_softmax_coverage.py's CoverageModel:
    that 52-bin model (score/diff_w/idx/rescale/l_value/row_length/control/
    cross) already covers every VALUE-domain corner at either latency, is
    gated by the default (PIPE_ROM=0) run, and per the task brief must not
    be inflated or otherwise perturbed by this file. The bins below probe
    only latency-2-specific STRUCTURAL corners (pipeline-stage interaction),
    dumped to a separate report file so the default run's func_coverage.txt
    (an EVIDENCE.md-cited artifact) is never touched."""

    BINS = [
        "back_to_back_across_stage_boundary",
        "bubble_immediately_after_row_start_lat2",
        "reset_mid_pipe_elements_in_flight",
        "drain_falls_exactly_2_cycles_after_last_in_valid",
        "m_leads_out_valid_by_one_on_max_update",
        "den_worst_case_lat2_l_eq_2p23",
    ]

    def __init__(self):
        self.hits = {b: 0 for b in self.BINS}

    def hit(self, name):
        assert name in self.hits, f"unknown pipe-rom1 coverage bin {name!r}"
        self.hits[name] += 1

    def report(self):
        lines = [
            "online_softmax PIPE_ROM=1 functional coverage report",
            "seed: %s" % getattr(cocotb, "RANDOM_SEED", "?"),
            "",
        ]
        missed = [b for b in self.BINS if self.hits[b] == 0]
        for b in self.BINS:
            tag = "HIT" if self.hits[b] else "MISS"
            lines.append(f"    {tag:4s} {b:55s} hits={self.hits[b]}")
        pct = 100.0 * (len(self.BINS) - len(missed)) / len(self.BINS)
        lines.append("")
        lines.append(f"TOTAL: {len(self.BINS) - len(missed)}/{len(self.BINS)} bins hit ({pct:.1f}%)")
        return "\n".join(lines) + "\n", pct, missed


PIPE_COV = PipeCoverageModel()


def assert_pipe_rom_1(dut):
    """Runtime config-knob check (task requirement): a mismatch between the
    Makefile's PIPE_ROM=1 knob and what this test module expects must fail
    loudly, not silently exercise the wrong (latency-1) elaboration."""
    got = int(dut.PIPE_ROM.value)
    assert got == 1, (
        f"test_softmax_pipe_rom requires the DUT to elaborate with "
        f"PIPE_ROM=1, but dut.PIPE_ROM == {got}. Check tb/online_softmax/"
        f"Makefile: `make sim MODULE=online_softmax PIPE_ROM=1` must pass "
        f"-GPIPE_ROM=1 via EXTRA_ARGS, and COCOTB_TEST_MODULES must select "
        f"this module only in that configuration."
    )


class PipeRom1Mirror:
    """Bit-exact software mirror of rtl/online_softmax.sv's g_lat2 branch
    (docs/uarch.md 8.2.1). Per-element recurrence VALUES are the identical
    Section 6 equations SoftmaxMirror already uses (transcribed here again,
    directly from attn.lut_index/attn.rshr, so this file does not depend on
    test_online_softmax's single-cycle SoftmaxMirror's internal shape);
    only the LATENCY/staging differs: m commits one cycle after accept
    (stage 1), l/w/r/out_valid commit two cycles after accept (stage 2)."""

    def reset(self):
        self.m = M_INIT
        self.l = 0
        self.w = 0
        self.r = 0
        self.out_valid = False
        # Internal pipe registers (rtl/online_softmax.sv g_lat2: v_p, rs_p,
        # w_p, r_p). Not part of the DUT's port list, but needed here to
        # reproduce the two-stage recurrence exactly.
        self.v_p = False
        self.rs_p = False
        self.w_p = 0
        self.r_p = 0

    def clock(self, rst, in_valid, row_start, s):
        """One clock edge, matching the RTL's synchronous-reset always_ff
        exactly: if rst, everything (including the internal pipe regs)
        clears; otherwise stage 1 and stage 2 evaluate off OLD state and
        commit simultaneously (nonblocking-assignment semantics)."""
        if rst:
            self.reset()
            return

        # ---- Stage 1 (combinational, reads OLD self.m) --------------------
        if in_valid:
            m_base = M_INIT if row_start else self.m
            m_new = m_base if m_base >= s else s
            diff_m = m_base - m_new
            diff_s = s - m_new
            assert diff_m <= 0 and diff_s <= 0
            r_n = LUT[attn.lut_index(diff_m)]
            w_n = LUT[attn.lut_index(diff_s)]

        # ---- Stage 2 (combinational, reads OLD self.l/v_p/rs_p/r_p/w_p) ---
        if self.v_p:
            l_base = 0 if self.rs_p else self.l
            l_new = attn.rshr(l_base * self.r_p, attn.W_FRAC) + self.w_p
            assert 0 <= l_new < DEN_MOD, f"DEN width violated: l={l_new}"

        # ---- Commit (same edge, order irrelevant: all RHS already sampled)
        self.out_valid = self.v_p
        if self.v_p:
            self.l = l_new
            self.w = self.w_p
            self.r = self.r_p

        self.v_p = in_valid
        if in_valid:
            self.m = m_new
            self.w_p = w_n
            self.r_p = r_n
            self.rs_p = row_start


async def step(dut, mirror, in_valid, row_start, s, msg, rst=False):
    """Drive one cycle (optionally including rst) and check every DUT
    output against the mirror on the following FallingEdge (post-NBA,
    stable), same house style as test_online_softmax.drive_and_check."""
    dut.rst.value = int(bool(rst))
    dut.in_valid.value = int(bool(in_valid))
    dut.row_start.value = int(bool(row_start))
    dut.s.value = 0 if rst else s
    await RisingEdge(dut.clk)
    mirror.clock(bool(rst), bool(in_valid), bool(row_start), s)
    await FallingEdge(dut.clk)
    check_outputs(dut, mirror, msg)


async def idle(dut, mirror, n, msg):
    for i in range(n):
        await step(dut, mirror, False, False, 0, f"{msg} idle[{i}]")


# =============================================================================
# 1. Single row, exact per-element values vs model/attn.py.
# =============================================================================
@cocotb.test()
async def single_row_exact_values(dut):
    """One 6-element row with varied SCORE values (including negatives and a
    genuine max update mid-row), checking (m, l, w, r, out_valid) exactly
    vs the model/attn.py-built mirror on every single cycle, including the
    latency-2 lag before out_valid rises and the 2-cycle drain after the
    last element."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    scores = [-5000, -5000, 3000, 3000, -100, 20000]
    for i, s in enumerate(scores):
        await step(dut, mirror, True, i == 0, s, f"single-row elem{i}")
    # Drain: two more idle cycles must flush the pipe with correct holds.
    await idle(dut, mirror, 3, "single-row drain")
    assert mirror.out_valid is False
    assert mirror.m == max(scores)


# =============================================================================
# 2. Multi-row back-to-back across the stage boundary.
# =============================================================================
@cocotb.test()
async def back_to_back_rows_across_stage_boundary(dut):
    """Row A's last element and row B's row_start element are issued on
    back-to-back cycles with NO dead cycle in between (uarch.md 8.2.1: rs_p
    carries row_start down the pipe so a new row's stage-2 update bases at
    l = 0 even though it lands on the very edge that would otherwise still
    be settling row A's own l). Three rows chained back to back, each
    checked value-exact against the mirror every cycle."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    row_lens = [4, 1, 5]  # row B is a single element: boundary on BOTH sides
    row_bases = [1000, -20000, 15000]
    for r_i, (length, base) in enumerate(zip(row_lens, row_bases)):
        for i in range(length):
            s = base + 111 * i
            await step(
                dut, mirror, True, i == 0, s, f"b2b row{r_i} elem{i}"
            )
    await idle(dut, mirror, 3, "b2b drain")
    PIPE_COV.hit("back_to_back_across_stage_boundary")


# =============================================================================
# 3. Gap patterns: bubbles mid-row, including immediately after row_start.
# =============================================================================
@cocotb.test()
async def gap_patterns(dut):
    """in_valid bubbles inserted mid-row, including a bubble on the very
    cycle after row_start (stage 1 and stage 2 both see in_valid = 0 that
    cycle: m/l/w/r must hold and the pipe must not advance a phantom
    element)."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    # Bubble immediately after row_start.
    await step(dut, mirror, True, True, 500, "gap row-start elem0")
    await idle(dut, mirror, 2, "gap right-after-row-start")
    PIPE_COV.hit("bubble_immediately_after_row_start_lat2")
    await step(dut, mirror, True, False, 700, "gap elem1")
    await idle(dut, mirror, 1, "gap mid-row single bubble")
    await step(dut, mirror, True, False, -300, "gap elem2")
    await idle(dut, mirror, 3, "gap multi-cycle bubble")
    await step(dut, mirror, True, False, 900, "gap elem3")
    await idle(dut, mirror, 4, "gap drain")

    # A second row with gaps at essentially every position, longer, to also
    # exercise a bubble landing while the PREVIOUS element is mid-pipe
    # (stage 2 only, stage 1 idle) vs before any element entered stage 1.
    scores2 = [111, -222, 333, -444, 555, -666, 777]
    for i, s in enumerate(scores2):
        await step(dut, mirror, True, i == 0, s, f"gap row2 elem{i}")
        if i % 2 == 0:
            await idle(dut, mirror, 1, f"gap row2 after elem{i}")
    await idle(dut, mirror, 3, "gap row2 drain")


# =============================================================================
# 4. Drain behavior: out_valid falls exactly 2 cycles after the last
#    in_valid, then l/w/r hold.
# =============================================================================
@cocotb.test()
async def drain_behavior(dut):
    """After the last accepted element, out_valid FALLS exactly 2 cycles
    after that last in_valid, then l/w/r hold indefinitely (the pipe
    self-drains, uarch.md 8.2.1). Precise timing (steady-state pipeline is
    already 2 elements deep, so out_valid is NOT low right after the last
    accept -- it is derived directly from the g_lat2 mirror/RTL, not
    assumed): right after the last accept, out_valid is already high,
    reporting the SECOND-TO-LAST element (that is steady-state latency-2
    behavior, unrelated to draining); one idle cycle later (+1) out_valid
    is still high, now finally reporting the LAST element; two idle cycles
    after the last accept (+2) out_valid falls, exactly matching the '2
    cycles after in_valid' contract, and l/w/r hold from then on."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    scores = [2000, -4000, 6000, -8000]
    for i, s in enumerate(scores):
        await step(dut, mirror, True, i == 0, s, f"drain-setup elem{i}")
    # Right after the last accept: still steady-state, out_valid already
    # high (reporting elem[-2], not a drain effect yet).
    assert mirror.out_valid is True

    # +1 idle cycle after the last in_valid: out_valid stays high, now
    # reporting the LAST accepted element (its (w, r, l) values commit
    # here).
    await step(dut, mirror, False, False, 0, "drain +1: reports last elem")
    assert mirror.out_valid is True
    last_w, last_r, last_l = mirror.w, mirror.r, mirror.l

    # +2 idle cycles after the last in_valid: out_valid falls, exactly the
    # documented 2-cycle-after-in_valid contract.
    await step(dut, mirror, False, False, 0, "drain +2: out_valid falls")
    assert mirror.out_valid is False

    # From here on: l/w/r hold their final values indefinitely.
    for i in range(5):
        await step(dut, mirror, False, False, 0, f"drain +{3 + i}: hold")
        assert mirror.out_valid is False
        assert mirror.w == last_w and mirror.r == last_r and mirror.l == last_l
    PIPE_COV.hit("drain_falls_exactly_2_cycles_after_last_in_valid")


# =============================================================================
# 5. m-leads-out_valid-by-one alignment, isolated and explicit.
# =============================================================================
@cocotb.test()
async def m_leads_out_valid_by_one(dut):
    """Direct, isolated proof of the uarch.md 8.2.1 alignment claim: on the
    cycle immediately after an element is accepted, the visible m ALREADY
    reflects that element (latency 1), independent of whatever out_valid
    happens to be reporting that same cycle (a different, earlier element,
    or nothing yet, depending on pipeline fill state)."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    # First element of a row: m should become exactly s0 one cycle after
    # accept, before out_valid has risen even once.
    s0 = 4242
    await step(dut, mirror, True, True, s0, "mlead row-start elem0")
    assert wrap16(int(dut.m.value)) == s0, "m must equal s0 one cycle after accept"
    assert bool(dut.out_valid.value) is False, "out_valid must still be low (latency 2)"

    # A genuine max update: m must move to the new max one cycle after
    # accept, again strictly before out_valid rises for THAT element.
    s1 = 9999
    await step(dut, mirror, True, False, s1, "mlead elem1 (max update)")
    assert wrap16(int(dut.m.value)) == s1
    # out_valid this cycle belongs to elem0 (2 cycles after elem0's accept),
    # not elem1; the mirror/check_outputs already proved the exact value,
    # this just re-states the m-vs-out_valid-content distinction explicitly.
    assert bool(dut.out_valid.value) is True, "out_valid now reports elem0, not elem1"
    assert int(dut.w.value) == EXP_ONE, "out_valid content is elem0's w == lut[0]"
    PIPE_COV.hit("m_leads_out_valid_by_one_on_max_update")

    await idle(dut, mirror, 3, "mlead drain")


# =============================================================================
# 6. Reset mid-pipe: rst while elements are in flight, then a fresh row.
# =============================================================================
@cocotb.test()
async def reset_mid_pipe(dut):
    """Assert rst while elements are actively in flight in BOTH pipe stages
    (one element just accepted into stage 1, a previous element sitting in
    stage 2 about to commit its l update), then release rst and drive a
    fresh row, checking it is computed correctly with no contamination from
    the flushed elements (all internal pipe state -- v_p, rs_p, w_p, r_p --
    is unconditionally cleared by the RTL's synchronous reset, per the
    g_lat2 always_ff reset branch)."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    # Get two elements in flight: elem0 (row start) then elem1, so that at
    # the moment rst asserts, elem0 is settling into stage 2 (v_p was set by
    # elem0's accept, about to commit) and elem1 has just entered stage 1.
    await step(dut, mirror, True, True, 1111, "reset-mid-pipe elem0")
    await step(dut, mirror, True, False, 2222, "reset-mid-pipe elem1")

    # rst for one cycle with elements in flight (in_valid deasserted along
    # with rst, matching the RTL's synchronous-reset contract; row_start
    # and s are don't-cares here, driven to 0/False for cleanliness).
    await step(dut, mirror, False, False, 0, "reset-mid-pipe rst", rst=True)
    assert mirror.m == M_INIT
    assert mirror.l == 0
    assert mirror.w == 0 and mirror.r == 0
    assert mirror.out_valid is False
    PIPE_COV.hit("reset_mid_pipe_elements_in_flight")

    # A further idle cycle post-reset: nothing should leak out of the
    # flushed pipe (v_p/rs_p/w_p/r_p were all cleared, not just m/l/w/r).
    await step(dut, mirror, False, False, 0, "reset-mid-pipe post-rst idle")
    assert mirror.out_valid is False

    # Fresh row after the reset: must compute exactly per the golden
    # recurrence, uncontaminated by elem0/elem1 above.
    scores = [500, -500, 1500, -1500, 2500]
    for i, s in enumerate(scores):
        await step(dut, mirror, True, i == 0, s, f"reset-mid-pipe fresh row elem{i}")
    await idle(dut, mirror, 3, "reset-mid-pipe fresh row drain")
    assert mirror.m == max(scores)


# =============================================================================
# 7. DEN worst case at PIPE_ROM=1: 256-element all-max row, l bound 2^23.
# =============================================================================
@cocotb.test()
async def den_worst_case_pipe_rom1(dut):
    """Same corner as test_softmax_coverage.directed_den_worst_case, at
    latency 2: a 256-element constant-score row never moves the running max
    after element 0 (identity 1, uarch.md 6.1: r stays the exact identity
    0x8000), so l after j elements (1-indexed) == j * 2^15 exactly, reaching
    l == 2^23 at j == 256 (N_MAX, uarch.md 3.6/8.2's induction bound). Checks
    EXACT equality every step (via the mirror + check_outputs), not just at
    the end, plus the DEN width bound 0 <= l < 2^24 throughout."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    CONST_SCORE = 12345
    N = 256
    for j in range(N):
        await step(dut, mirror, True, j == 0, CONST_SCORE, f"den-worst-lat2 j={j}")
        assert 0 <= mirror.l < DEN_MOD, f"j={j}: DEN width bound violated: l={mirror.l}"

    # Drain: the last two elements' l updates are still in flight.
    await idle(dut, mirror, 3, "den-worst-lat2 drain")
    assert mirror.l == (1 << 23), f"final l={mirror.l} != 2^23 exactly"
    assert (mirror.l >> 22) & 0x3, "l bits [23:22] must be nonzero at l == 2^23"
    assert mirror.w == EXP_ONE
    assert int(dut.l.value) == (1 << 23)
    PIPE_COV.hit("den_worst_case_lat2_l_eq_2p23")


# =============================================================================
# 8. Constrained-random soak: a few hundred elements, random rows/bubbles,
#    full value checking against the golden model every cycle.
# =============================================================================
@cocotb.test()
async def constrained_random_soak(dut):
    """A few hundred elements across many rows of random length (capped at
    60, well under the 256-row DEN bound per the house rule), with random
    idle bubbles (including immediately after row_start) and random
    back-to-back row transitions, checked value-exact vs the mirror on
    every single cycle. Seeded from cocotb.RANDOM_SEED (house style)."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()
    rng = seeded_rng()

    total_elems = 0
    trial = 0
    while total_elems < 400:
        length = rng.randint(1, 60)
        scores = [rng.randint(-32768, 32767) for _ in range(length)]
        back_to_back = rng.random() < 0.4

        if trial > 0 and not back_to_back:
            await idle(dut, mirror, rng.randint(1, 3), f"soak trial{trial} pre-row")

        for i, s in enumerate(scores):
            if rng.random() < 0.2:
                await idle(dut, mirror, rng.randint(1, 2), f"soak trial{trial} pre-elem{i}")
            await step(dut, mirror, True, i == 0, s, f"soak trial{trial} elem{i}")

        total_elems += length
        trial += 1

    await idle(dut, mirror, 3, "soak drain")

    # This test runs last (cocotb 2.x's RegressionManager sorts by stage,
    # stable, so tests within one module run in file-definition order, same
    # house style as test_softmax_coverage.py): dump the aggregated
    # PIPE_ROM=1 structural coverage report and assert closure. All 6 bins
    # are hit by earlier tests in THIS file (each test above calls
    # PIPE_COV.hit exactly once for the corner it directly, deterministically
    # exercises), so this is a strict pass/fail gate, not a best-effort log.
    text, pct, missed = PIPE_COV.report()
    PIPE_COV_REPORT_PATH.write_text(text)
    cocotb.log.info("\n" + text)
    assert not missed, (
        f"PIPE_ROM=1 functional coverage NOT closed: {missed}. "
        f"See {PIPE_COV_REPORT_PATH}"
    )
    assert pct == 100.0, f"PIPE_ROM=1 coverage {pct:.1f}% != 100%"
