"""attention_top cocotb testbench (docs/uarch.md 8.3), bit-exact against
model/attn.py attn_fixed.

Load port addr = {row[5:0], col[3:0]}; output read is registered (one cycle).
Drives on RisingEdge, samples on FallingEdge; RNGs seed from cocotb.RANDOM_SEED.
"""

import pathlib
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "model"))
import attn  # noqa: E402
import crosscheck  # noqa: E402

LUT = attn.gen_exp_lut()
D = attn.D_DIM

CYCLES_PATH = pathlib.Path(__file__).resolve().parent / "cycles.txt"
FUNC_COV_PATH = pathlib.Path(__file__).resolve().parent / "func_coverage.txt"


class TopCoverage:
    """Functional coverage bins; report format is gated by scripts/check_coverage.py --func."""

    GROUPS = {
        # nblk = 1, 2, 3, 4, 5, 8, 9, 16 (12/20/36 cover non-power-of-two counts)
        "n_len": ["n_4", "n_8", "n_12", "n_16", "n_20", "n_32", "n_36", "n_64"],
        "control": [
            "back_to_back_runs_no_reset",
            "rst_mid_run",
            "start_while_busy_ignored",
            "sel3_write_ignored",
        ],
        "data": [
            "input_all_zero", "input_all_max", "input_all_min",
            "input_v_extremes", "output_eq_127", "output_eq_m128",
            "output_negative", "output_positive",
        ],
        "readback": ["random_order_readback", "repeated_read_stable"],
    }

    def __init__(self):
        self.hits = {g: {n: 0 for n in names} for g, names in self.GROUPS.items()}

    def hit(self, group, name):
        self.hits[group][name] += 1

    def report(self):
        lines = []
        total = hit = 0
        for g, names in self.GROUPS.items():
            g_hit = sum(1 for n in names if self.hits[g][n] > 0)
            total += len(names)
            hit += g_hit
            lines.append(f"[{g}] {g_hit}/{len(names)} reachable bins hit "
                         f"({100.0 * g_hit / len(names):.1f}%), 0 documented-unreachable")
            for n in names:
                c = self.hits[g][n]
                lines.append(f"    {'HIT' if c else 'MISS':11s} {g}.{n:28s} hits={c}")
        pct = 100.0 * hit / total
        missed = [f"  {g}.{n}" for g, names in self.GROUPS.items()
                  for n in names if self.hits[g][n] == 0]
        header = [
            "attention_top functional coverage report",
            "seed: %s" % getattr(cocotb, "RANDOM_SEED", "?"),
            f"TOTAL: {hit}/{total} reachable bins hit ({pct:.1f}%), "
            f"0 documented-unreachable, {total} bins defined",
            "",
        ]
        tail = ["", "Unhit reachable bins (coverage gap, should be empty at closure):"]
        tail += missed if missed else ["  (none)"]
        return "\n".join(header + lines + tail) + "\n", pct, missed


COV = TopCoverage()


def observe_inputs(q, k, v):
    flat = [x for m in (q, k, v) for r in m for x in r]
    if all(x == 0 for x in flat):
        COV.hit("data", "input_all_zero")
    if all(x == 127 for x in flat):
        COV.hit("data", "input_all_max")
    if all(x == -128 for x in flat):
        COV.hit("data", "input_all_min")
    if all(x in (127, -128) for r in v for x in r):
        COV.hit("data", "input_v_extremes")


def observe_outputs(out):
    flat = [x for r in out for x in r]
    if any(x == 127 for x in flat):
        COV.hit("data", "output_eq_127")
    if any(x == -128 for x in flat):
        COV.hit("data", "output_eq_m128")
    if any(x < 0 for x in flat):
        COV.hit("data", "output_negative")
    if any(x > 0 for x in flat):
        COV.hit("data", "output_positive")


def seeded_rng():
    """RNG seeded from cocotb's per-test seed."""
    seed = getattr(cocotb, "RANDOM_SEED", None)
    if seed is None:
        seed = 1
    return random.Random(seed)


def to_u8(v):
    """Signed int in [-128, 127] -> unsigned byte for the wdata bus."""
    assert -128 <= v <= 127, f"ACT value out of range: {v}"
    return v & 0xFF


def wrap8(v):
    """Unsigned byte read back from rd_data -> signed int8."""
    v &= 0xFF
    return v - 256 if v >= 128 else v


def cycle_formula(n_len):
    """nblk groups of (16*nblk+156) cycles, +1 for the start-accept edge."""
    nblk = n_len // 4
    return nblk * (16 * nblk + 156) + 1


def golden(q, k, v):
    return attn.attn_fixed(q, k, v, LUT)


def assert_matrix_equal(got, expected, msg):
    n = len(expected)
    d = len(expected[0])
    for row in range(n):
        for col in range(d):
            assert got[row][col] == expected[row][col], (
                f"{msg}: out[{row}][{col}] rtl={got[row][col]} "
                f"golden={expected[row][col]}"
            )


async def start_and_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.sel.value = 0
    dut.addr.value = 0
    dut.wdata.value = 0
    dut.we.value = 0
    dut.n_len.value = 0
    dut.start.value = 0
    dut.rd_addr.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def load_matrices(dut, q, k, v):
    """Write Q, K, V one byte per cycle, cycling sel 0/1/2 per (row, col)."""
    n = len(q)
    d = len(q[0])
    observe_inputs(q, k, v)
    dut.we.value = 1
    for row in range(n):
        for col in range(d):
            for sel, mat in ((0, q), (1, k), (2, v)):
                dut.sel.value = sel
                dut.addr.value = (row << 4) | col
                dut.wdata.value = to_u8(mat[row][col])
                await RisingEdge(dut.clk)
    dut.we.value = 0
    await RisingEdge(dut.clk)


async def read_one(dut, row, col):
    """Read one output byte; rd_data is valid one edge after rd_addr."""
    dut.rd_addr.value = (row << 4) | col
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    return wrap8(int(dut.rd_data.value))


async def read_out(dut, n, d=D):
    out = [[0] * d for _ in range(n)]
    for row in range(n):
        for col in range(d):
            out[row][col] = await read_one(dut, row, col)
    observe_outputs(out)
    return out


async def run(dut, n_len):
    """Pulse start, check the busy/done handshake every cycle, return cycle_count."""
    expected_cycles = cycle_formula(n_len)
    COV.hit("n_len", f"n_{n_len}")
    dut.n_len.value = n_len
    dut.start.value = 1

    margin = 300
    timeout_cycles = expected_cycles + margin
    cyc = 0
    while True:
        await RisingEdge(dut.clk)
        if cyc == 0:
            # S_COMPUTE registers on this edge, so start is already accepted.
            dut.start.value = 0
        await FallingEdge(dut.clk)
        cyc += 1
        busy_now = bool(dut.busy.value)
        done_now = bool(dut.done.value)
        assert not (busy_now and done_now), (
            f"n_len={n_len} cyc={cyc}: busy and done both high "
            "(mutual exclusion violated, uarch.md 8.3)"
        )
        if cyc == 1:
            assert busy_now, (
                f"n_len={n_len}: busy must already read 1 on the cycle "
                "right after the start-accept edge (state registers "
                "S_COMPUTE on that same edge, uarch.md 8.3)"
            )
            assert int(dut.cycle_count.value) == 1, (
                f"n_len={n_len}: cycle_count must read exactly 1 on the "
                "cycle right after the accepted start edge (uarch.md 8.3)"
            )
        if done_now:
            got_cycles = int(dut.cycle_count.value)
            assert got_cycles == expected_cycles, (
                f"n_len={n_len}: cycle_count={got_cycles} != formula "
                f"{expected_cycles} = nblk*(16*nblk+156)+1 (uarch.md 8.3)"
            )
            return got_cycles
        assert busy_now, (
            f"n_len={n_len} cyc={cyc}: busy dropped low mid-run without "
            "done (uarch.md 8.3: busy = (state != S_IDLE) throughout a run)"
        )
        if cyc > timeout_cycles:
            raise TimeoutError(
                f"n_len={n_len}: run did not complete within "
                f"{timeout_cycles} cycles (formula predicts {expected_cycles})"
            )


@cocotb.test()
async def end_to_end_golden(dut):
    """One random case per n in 4..64; writes the n vs cycle_count table to cycles.txt."""
    await start_and_reset(dut)
    rng = seeded_rng()
    cycles_log = []

    for n in (4, 8, 16, 32, 64):
        q = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
        k = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
        v = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
        await load_matrices(dut, q, k, v)
        got_cycles = await run(dut, n)
        rtl_out = await read_out(dut, n)
        assert_matrix_equal(rtl_out, golden(q, k, v), f"end_to_end_golden n={n}")
        cycles_log.append((n, got_cycles))
        dut._log.info(f"end_to_end_golden: n={n} cycle_count={got_cycles}")

    with open(CYCLES_PATH, "w") as f:
        f.write("# n cycle_count  (docs/uarch.md 8.3: nblk*(16*nblk+156)+1)\n")
        for n, c in cycles_log:
            f.write(f"{n} {c}\n")
    dut._log.info(f"n-vs-cycle_count table: {cycles_log}")


@cocotb.test()
async def corners(dut):
    """All-zero, all-max, all-min, V extremes, and the monotonic max-update case."""
    await start_and_reset(dut)
    rng = seeded_rng()
    n = 8

    zeros = [[0] * D for _ in range(n)]
    await load_matrices(dut, zeros, zeros, zeros)
    await run(dut, n)
    got = await read_out(dut, n)
    assert_matrix_equal(got, golden(zeros, zeros, zeros), "corners: all-zeros")

    allmax = [[127] * D for _ in range(n)]
    await load_matrices(dut, allmax, allmax, allmax)
    await run(dut, n)
    got = await read_out(dut, n)
    assert_matrix_equal(got, golden(allmax, allmax, allmax), "corners: all+127")

    allmin = [[-128] * D for _ in range(n)]
    await load_matrices(dut, allmin, allmin, allmin)
    await run(dut, n)
    got = await read_out(dut, n)
    assert_matrix_equal(got, golden(allmin, allmin, allmin), "corners: all-128")

    q = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
    k = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
    v_ext = [[127 if (r + c) % 2 == 0 else -128 for c in range(D)] for r in range(n)]
    await load_matrices(dut, q, k, v_ext)
    await run(dut, n)
    got = await read_out(dut, n)
    assert_matrix_equal(got, golden(q, k, v_ext), "corners: V extremes")

    n16 = 16
    qm, km, vm = crosscheck.monotonic_case(n16)
    await load_matrices(dut, qm, km, vm)
    await run(dut, n16)
    got = await read_out(dut, n16)
    assert_matrix_equal(got, golden(qm, km, vm), "corners: monotonic-n16")


@cocotb.test()
async def multi_run_no_reset(dut):
    """Two runs back to back without reset: start alone must reinitialize all state."""
    await start_and_reset(dut)
    rng = seeded_rng()
    n = 8

    for case_i in range(2):
        q = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
        k = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
        v = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
        await load_matrices(dut, q, k, v)
        await run(dut, n)
        got = await read_out(dut, n)
        assert_matrix_equal(got, golden(q, k, v), f"multi_run_no_reset case{case_i}")
        if case_i > 0:
            COV.hit("control", "back_to_back_runs_no_reset")


@cocotb.test()
async def rst_mid_run(dut):
    """Reset 300 cycles into an n=64 run, check idle, then a clean run."""
    await start_and_reset(dut)
    rng = seeded_rng()
    n = 64
    q = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
    k = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
    v = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
    await load_matrices(dut, q, k, v)

    dut.n_len.value = n
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    for _ in range(300):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert bool(dut.busy.value), (
        "rst_mid_run setup error: expected still busy 300 cycles into an "
        "n=64 (6593-cycle) run"
    )

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await FallingEdge(dut.clk)
    assert not bool(dut.busy.value), "rst mid-run must drop busy"
    assert not bool(dut.done.value), "rst mid-run must not assert done"
    assert int(dut.cycle_count.value) == 0, "rst mid-run must clear cycle_count"
    COV.hit("control", "rst_mid_run")

    for _ in range(3):
        await RisingEdge(dut.clk)

    n2 = 8
    q2 = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n2)]
    k2 = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n2)]
    v2 = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n2)]
    await load_matrices(dut, q2, k2, v2)
    await run(dut, n2)
    got = await read_out(dut, n2)
    assert_matrix_equal(
        got, golden(q2, k2, v2), "rst_mid_run: clean run after mid-run reset"
    )


@cocotb.test()
async def random_regression(dut):
    """10 seeded-random cases at random n in {4,8,16,32,64}."""
    await start_and_reset(dut)
    rng = seeded_rng()
    sizes = [4, 8, 16, 32, 64]

    for case_i in range(10):
        n = rng.choice(sizes)
        q = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
        k = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
        v = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
        await load_matrices(dut, q, k, v)
        await run(dut, n)
        got = await read_out(dut, n)
        assert_matrix_equal(got, golden(q, k, v), f"random_regression case{case_i} n={n}")


@cocotb.test()
async def write_port_readback(dut):
    """Shuffled-address writes; repeated and random-order output reads."""
    await start_and_reset(dut)
    rng = seeded_rng()
    n = 8

    addrs = [(row, col) for row in range(n) for col in range(D)]
    rng.shuffle(addrs)
    q = [[0] * D for _ in range(n)]
    k = [[0] * D for _ in range(n)]
    v = [[0] * D for _ in range(n)]
    for row, col in addrs:
        q[row][col] = rng.randint(-128, 127)
        k[row][col] = rng.randint(-128, 127)
        v[row][col] = rng.randint(-128, 127)

    dut.we.value = 1
    for row, col in addrs:
        for sel, mat in ((0, q), (1, k), (2, v)):
            dut.sel.value = sel
            dut.addr.value = (row << 4) | col
            dut.wdata.value = to_u8(mat[row][col])
            await RisingEdge(dut.clk)
    dut.we.value = 0
    await RisingEdge(dut.clk)

    await run(dut, n)
    expected = golden(q, k, v)

    r0, c0 = 3, 5
    val_a = await read_one(dut, r0, c0)
    val_b = await read_one(dut, r0, c0)
    assert val_a == val_b == expected[r0][c0], (
        f"write_port_readback: repeated read of ({r0},{c0}) unstable or "
        f"wrong: {val_a}, {val_b} vs golden {expected[r0][c0]}"
    )
    COV.hit("readback", "repeated_read_stable")

    read_addrs = [(row, col) for row in range(n) for col in range(D)]
    rng.shuffle(read_addrs)
    for row, col in read_addrs:
        got = await read_one(dut, row, col)
        assert got == expected[row][col], (
            f"write_port_readback: out[{row}][{col}] rtl={got} "
            f"golden={expected[row][col]} (random-order read)"
        )
    COV.hit("readback", "random_order_readback")


@cocotb.test()
async def nonpow2_group_counts(dut):
    """n_len 12/20/36 (nblk 3/5/9) exercise the nblk_m1 compares and odd rollover."""
    await start_and_reset(dut)
    rng = seeded_rng()
    for n in (12, 20, 36):
        q = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
        k = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
        v = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
        await load_matrices(dut, q, k, v)
        await run(dut, n)
        got = await read_out(dut, n)
        assert_matrix_equal(got, golden(q, k, v), f"nonpow2_group_counts n={n}")


@cocotb.test()
async def start_while_busy_ignored(dut):
    """A start (with a different n_len) during a run is ignored."""
    await start_and_reset(dut)
    rng = seeded_rng()
    n = 16
    q = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
    k = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
    v = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
    await load_matrices(dut, q, k, v)
    COV.hit("n_len", f"n_{n}")

    dut.n_len.value = n
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    for _ in range(50):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert bool(dut.busy.value), "setup error: expected busy 50 cycles into an n=16 run"

    dut.n_len.value = 64
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0
    dut.n_len.value = n

    expected_cycles = cycle_formula(n)
    for _ in range(expected_cycles + 300):
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        assert not (bool(dut.busy.value) and bool(dut.done.value))
        if bool(dut.done.value):
            got_cycles = int(dut.cycle_count.value)
            assert got_cycles == expected_cycles, (
                f"start-while-busy was NOT ignored: cycle_count={got_cycles} != "
                f"{expected_cycles} for the original n_len={n}"
            )
            break
    else:
        raise TimeoutError("start_while_busy_ignored: run did not complete")
    COV.hit("control", "start_while_busy_ignored")
    got = await read_out(dut, n)
    assert_matrix_equal(got, golden(q, k, v), "start_while_busy_ignored: outputs")


@cocotb.test()
async def sel3_write_ignored(dut):
    """Writes with sel = 3 (no-write encoding) must not change any matrix."""
    await start_and_reset(dut)
    rng = seeded_rng()
    n = 8
    q = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
    k = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
    v = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(n)]
    await load_matrices(dut, q, k, v)

    dut.we.value = 1
    dut.sel.value = 3
    for row in range(n):
        for col in range(D):
            dut.addr.value = (row << 4) | col
            dut.wdata.value = rng.randint(0, 255)
            await RisingEdge(dut.clk)
    dut.we.value = 0
    dut.sel.value = 0
    await RisingEdge(dut.clk)
    COV.hit("control", "sel3_write_ignored")

    await run(dut, n)
    got = await read_out(dut, n)
    assert_matrix_equal(got, golden(q, k, v), "sel3_write_ignored: sel=3 must not write")


@cocotb.test()
async def test_zz_coverage_closure(dut):
    """Last test (cocotb runs in file order): write the coverage report, fail on any miss."""
    text, pct, missed = COV.report()
    FUNC_COV_PATH.write_text(text)
    dut._log.info("\n" + text)
    assert not missed, f"attention_top functional coverage NOT closed: {missed}"
    assert pct == 100.0, f"coverage {pct:.1f}% != 100%"
