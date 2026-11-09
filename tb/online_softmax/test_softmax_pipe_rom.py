"""online_softmax PIPE_ROM=1 (latency-2, docs/uarch.md 8.2.1) testbench:
checks m, l, w, r, out_valid every cycle against a two-stage mirror of the
g_lat2 RTL built on model/attn.py, plus latency-2 structural coverage.
Run with `make sim MODULE=online_softmax PIPE_ROM=1`.
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
    """Latency-2-only structural bins, reported separately from the default
    run's func_coverage.txt (value bins live in test_softmax_coverage.py)."""

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
    """Fail if the DUT was not elaborated with PIPE_ROM=1."""
    got = int(dut.PIPE_ROM.value)
    assert got == 1, (
        f"test_softmax_pipe_rom requires the DUT to elaborate with "
        f"PIPE_ROM=1, but dut.PIPE_ROM == {got}. Check tb/online_softmax/"
        f"Makefile: `make sim MODULE=online_softmax PIPE_ROM=1` must pass "
        f"-GPIPE_ROM=1 via EXTRA_ARGS, and COCOTB_TEST_MODULES must select "
        f"this module only in that configuration."
    )


class PipeRom1Mirror:
    """Bit-exact mirror of rtl/online_softmax.sv g_lat2: m commits one cycle
    after accept, l/w/r/out_valid two cycles after."""

    def reset(self):
        self.m = M_INIT
        self.l = 0
        self.w = 0
        self.r = 0
        self.out_valid = False
        # Internal RTL pipe registers.
        self.v_p = False
        self.rs_p = False
        self.w_p = 0
        self.r_p = 0

    def clock(self, rst, in_valid, row_start, s):
        """One clock edge; both stages read old state and commit together."""
        if rst:
            self.reset()
            return

        # ---- Stage 1 (reads old m) ----
        if in_valid:
            m_base = M_INIT if row_start else self.m
            m_new = m_base if m_base >= s else s
            diff_m = m_base - m_new
            diff_s = s - m_new
            assert diff_m <= 0 and diff_s <= 0
            r_n = LUT[attn.lut_index(diff_m)]
            w_n = LUT[attn.lut_index(diff_s)]

        # ---- Stage 2 (reads old l and pipe regs) ----
        if self.v_p:
            l_base = 0 if self.rs_p else self.l
            l_new = attn.rshr(l_base * self.r_p, attn.W_FRAC) + self.w_p
            assert 0 <= l_new < DEN_MOD, f"DEN width violated: l={l_new}"

        # ---- Commit (order irrelevant, all inputs already sampled) ----
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


def observe_pipe_bins(mirror, rst, in_valid, row_start, pre):
    """Sample the structural bins; `pre` is mirror state before the edge."""
    pre_m, pre_v_p, pre_rs_p, pre_ov = pre
    if rst and pre_v_p:
        PIPE_COV.hit("reset_mid_pipe_elements_in_flight")
    if in_valid and row_start and pre_v_p:
        # new row enters stage 1 as the previous element commits in stage 2
        PIPE_COV.hit("back_to_back_across_stage_boundary")
    if (not in_valid) and (not rst) and pre_v_p and pre_rs_p:
        PIPE_COV.hit("bubble_immediately_after_row_start_lat2")
    if pre_ov and not mirror.out_valid:
        PIPE_COV.hit("drain_falls_exactly_2_cycles_after_last_in_valid")
    if in_valid and not row_start and not rst and mirror.m != pre_m:
        # m commits at latency 1, ahead of out_valid
        PIPE_COV.hit("m_leads_out_valid_by_one_on_max_update")
    if mirror.l == (1 << 23):
        PIPE_COV.hit("den_worst_case_lat2_l_eq_2p23")


async def step(dut, mirror, in_valid, row_start, s, msg, rst=False):
    """Drive one cycle, check outputs on the FallingEdge, sample coverage."""
    pre = (mirror.m, mirror.v_p, mirror.rs_p, mirror.out_valid)
    dut.rst.value = int(bool(rst))
    dut.in_valid.value = int(bool(in_valid))
    dut.row_start.value = int(bool(row_start))
    dut.s.value = 0 if rst else s
    await RisingEdge(dut.clk)
    mirror.clock(bool(rst), bool(in_valid), bool(row_start), s)
    await FallingEdge(dut.clk)
    check_outputs(dut, mirror, msg)
    observe_pipe_bins(mirror, bool(rst), bool(in_valid), bool(row_start), pre)


async def idle(dut, mirror, n, msg):
    for i in range(n):
        await step(dut, mirror, False, False, 0, f"{msg} idle[{i}]")


@cocotb.test()
async def single_row_exact_values(dut):
    """One 6-element row with a mid-row max update, fill and drain included."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    scores = [-5000, -5000, 3000, 3000, -100, 20000]
    for i, s in enumerate(scores):
        await step(dut, mirror, True, i == 0, s, f"single-row elem{i}")
    await idle(dut, mirror, 3, "single-row drain")
    assert mirror.out_valid is False
    assert mirror.m == max(scores)


@cocotb.test()
async def back_to_back_rows_across_stage_boundary(dut):
    """Three rows with no dead cycle between them (rs_p resets l in stage 2)."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    row_lens = [4, 1, 5]  # row B is a single element: boundary on both sides
    row_bases = [1000, -20000, 15000]
    for r_i, (length, base) in enumerate(zip(row_lens, row_bases)):
        for i in range(length):
            s = base + 111 * i
            await step(
                dut, mirror, True, i == 0, s, f"b2b row{r_i} elem{i}"
            )
    await idle(dut, mirror, 3, "b2b drain")


@cocotb.test()
async def gap_patterns(dut):
    """in_valid bubbles mid-row, including right after row_start."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    await step(dut, mirror, True, True, 500, "gap row-start elem0")
    await idle(dut, mirror, 2, "gap right-after-row-start")
    await step(dut, mirror, True, False, 700, "gap elem1")
    await idle(dut, mirror, 1, "gap mid-row single bubble")
    await step(dut, mirror, True, False, -300, "gap elem2")
    await idle(dut, mirror, 3, "gap multi-cycle bubble")
    await step(dut, mirror, True, False, 900, "gap elem3")
    await idle(dut, mirror, 4, "gap drain")

    # Bubbles while the previous element is still in stage 2.
    scores2 = [111, -222, 333, -444, 555, -666, 777]
    for i, s in enumerate(scores2):
        await step(dut, mirror, True, i == 0, s, f"gap row2 elem{i}")
        if i % 2 == 0:
            await idle(dut, mirror, 1, f"gap row2 after elem{i}")
    await idle(dut, mirror, 3, "gap row2 drain")


@cocotb.test()
async def drain_behavior(dut):
    """out_valid falls exactly 2 cycles after the last in_valid, then l/w/r hold."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    scores = [2000, -4000, 6000, -8000]
    for i, s in enumerate(scores):
        await step(dut, mirror, True, i == 0, s, f"drain-setup elem{i}")
    # Steady state: out_valid reports the second-to-last element.
    assert mirror.out_valid is True

    # +1: reports the last element.
    await step(dut, mirror, False, False, 0, "drain +1: reports last elem")
    assert mirror.out_valid is True
    last_w, last_r, last_l = mirror.w, mirror.r, mirror.l

    await step(dut, mirror, False, False, 0, "drain +2: out_valid falls")
    assert mirror.out_valid is False

    for i in range(5):
        await step(dut, mirror, False, False, 0, f"drain +{3 + i}: hold")
        assert mirror.out_valid is False
        assert mirror.w == last_w and mirror.r == last_r and mirror.l == last_l


@cocotb.test()
async def m_leads_out_valid_by_one(dut):
    """m reflects an element one cycle after accept, while out_valid reports an earlier one."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    s0 = 4242
    await step(dut, mirror, True, True, s0, "mlead row-start elem0")
    assert wrap16(int(dut.m.value)) == s0, "m must equal s0 one cycle after accept"
    assert bool(dut.out_valid.value) is False, "out_valid must still be low (latency 2)"

    s1 = 9999
    await step(dut, mirror, True, False, s1, "mlead elem1 (max update)")
    assert wrap16(int(dut.m.value)) == s1
    assert bool(dut.out_valid.value) is True, "out_valid now reports elem0, not elem1"
    assert int(dut.w.value) == EXP_ONE, "out_valid content is elem0's w == lut[0]"

    await idle(dut, mirror, 3, "mlead drain")


@cocotb.test()
async def reset_mid_pipe(dut):
    """rst with elements in both stages, then a fresh row must be uncontaminated."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    await step(dut, mirror, True, True, 1111, "reset-mid-pipe elem0")
    await step(dut, mirror, True, False, 2222, "reset-mid-pipe elem1")

    await step(dut, mirror, False, False, 0, "reset-mid-pipe rst", rst=True)
    assert mirror.m == M_INIT
    assert mirror.l == 0
    assert mirror.w == 0 and mirror.r == 0
    assert mirror.out_valid is False

    # Nothing may leak out of the flushed pipe regs.
    await step(dut, mirror, False, False, 0, "reset-mid-pipe post-rst idle")
    assert mirror.out_valid is False

    scores = [500, -500, 1500, -1500, 2500]
    for i, s in enumerate(scores):
        await step(dut, mirror, True, i == 0, s, f"reset-mid-pipe fresh row elem{i}")
    await idle(dut, mirror, 3, "reset-mid-pipe fresh row drain")
    assert mirror.m == max(scores)


@cocotb.test()
async def den_worst_case_pipe_rom1(dut):
    """256-element constant row: l reaches exactly 2^23 (uarch.md 3.6) at latency 2."""
    assert_pipe_rom_1(dut)
    await start_and_reset(dut)
    mirror = PipeRom1Mirror()
    mirror.reset()

    CONST_SCORE = 12345
    N = 256
    for j in range(N):
        await step(dut, mirror, True, j == 0, CONST_SCORE, f"den-worst-lat2 j={j}")
        assert 0 <= mirror.l < DEN_MOD, f"j={j}: DEN width bound violated: l={mirror.l}"

    # The last two l updates are still in flight.
    await idle(dut, mirror, 3, "den-worst-lat2 drain")
    assert mirror.l == (1 << 23), f"final l={mirror.l} != 2^23 exactly"
    assert (mirror.l >> 22) & 0x3, "l bits [23:22] must be nonzero at l == 2^23"
    assert mirror.w == EXP_ONE
    assert int(dut.l.value) == (1 << 23)


@cocotb.test()
async def constrained_random_soak(dut):
    """Random rows (length <= 60), bubbles and back-to-back rows; closes coverage."""
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

    # Last test in file order, so the report covers every test.
    text, pct, missed = PIPE_COV.report()
    PIPE_COV_REPORT_PATH.write_text(text)
    cocotb.log.info("\n" + text)
    assert not missed, (
        f"PIPE_ROM=1 functional coverage NOT closed: {missed}. "
        f"See {PIPE_COV_REPORT_PATH}"
    )
    assert pct == 100.0, f"PIPE_ROM=1 coverage {pct:.1f}% != 100%"
