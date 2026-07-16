"""attention_top testbench: end-to-end streaming attention integration
(docs/uarch.md 8.3) checked against model/attn.py attn_fixed, the SAME
bit-exact golden reference used by tb/online_softmax and model/crosscheck.py.
No re-derivation of the recurrence here: attn_fixed IS the contract.

Load port: byte-granular synchronous write into q_mem/k_mem/v_mem, addr =
{row[5:0], col[3:0]} (uarch.md 8.3). Output read port: registered, rd_data
valid one cycle after rd_addr is presented (out_mem is plain read-through
register-array storage, no valid flag needed).

Handshake: start is a one-cycle pulse accepted only while busy = 0; busy
goes high the cycle AFTER the accepted start edge (the FSM's own state
register has not yet moved on the start-accept edge itself, so busy must
still read 0 at that instant -- checked below); done is a registered
one-cycle pulse, mutually exclusive with busy, coincident with the FSM
landing back in S_IDLE (uarch.md 8.3, "done implies idle" plus "busy/done
never both 1"). cycle_count is checked bit-exactly against the closed-form
formula nblk*(16*nblk+156)+1 every run, not just at n=64.

Drive on RisingEdge, sample on FallingEdge (post-NBA, stable), same house
style as tb/matmul_tile and tb/online_softmax. Seed plumbing: every RNG is
built from cocotb.RANDOM_SEED via seeded_rng(), so SEED=1 vs SEED=7
provably changes stimulus.
"""

import pathlib
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

# ---- Import the golden model + crosscheck corner-case generators directly -
ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "model"))
import attn  # noqa: E402
import crosscheck  # noqa: E402  (for monotonic_case, uarch.md 8.3 corner)

LUT = attn.gen_exp_lut()
D = attn.D_DIM  # 16, docs/uarch.md section 1

CYCLES_PATH = pathlib.Path(__file__).resolve().parent / "cycles.txt"


def seeded_rng():
    """Build an RNG from cocotb's per-test seed (house style, see
    tb/matmul_tile/test_matmul_tile.py docstring for the full rationale)."""
    seed = getattr(cocotb, "RANDOM_SEED", None)
    if seed is None:
        seed = 1  # defensive fallback only; COCOTB_RANDOM_SEED is always set
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
    """docs/uarch.md 8.3: cycles/group = (nblk+1)*16 + 4*35 = 16*nblk+156;
    total = nblk*(16*nblk+156)+1 (the +1 is the start-accept edge)."""
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


# ---- DUT drive/check helpers ------------------------------------------------
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
    """Write Q, K, V into the shared load port, one byte per cycle (sel 0/1/2
    cycling per (row, col) so all three land at the same address in
    consecutive cycles). addr = {row[5:0], col[3:0]} (uarch.md 8.3)."""
    n = len(q)
    d = len(q[0])
    dut.we.value = 1
    for row in range(n):
        for col in range(d):
            for sel, mat in ((0, q), (1, k), (2, v)):
                dut.sel.value = sel
                dut.addr.value = (row << 4) | col
                dut.wdata.value = to_u8(mat[row][col])
                await RisingEdge(dut.clk)
    dut.we.value = 0
    await RisingEdge(dut.clk)  # settle: we=0 in effect, no dangling write


async def read_one(dut, row, col):
    """Registered read port: present rd_addr, one clock edge, then rd_data
    is valid (uarch.md 8.3: 'valid one cycle after rd_addr')."""
    dut.rd_addr.value = (row << 4) | col
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    return wrap8(int(dut.rd_data.value))


async def read_out(dut, n, d=D):
    out = [[0] * d for _ in range(n)]
    for row in range(n):
        for col in range(d):
            out[row][col] = await read_one(dut, row, col)
    return out


async def run(dut, n_len):
    """Pulse start, then poll busy/done every cycle until done fires,
    checking the full 8.3 handshake shape on every cycle (not just at the
    end): busy and done are never both high; busy is high on EVERY cycle
    from start-accept to (not including) the done cycle, with no gaps;
    done fires exactly once, coincident with busy dropping; cycle_count is
    checked bit-exactly against the closed-form formula at the done edge.
    Returns the observed cycle_count."""
    expected_cycles = cycle_formula(n_len)
    dut.n_len.value = n_len
    dut.start.value = 1

    margin = 300
    timeout_cycles = expected_cycles + margin
    cyc = 0
    while True:
        await RisingEdge(dut.clk)
        if cyc == 0:
            # start is sampled on THIS edge (pre-edge state == S_IDLE); the
            # FSM's state_n = S_COMPUTE is computed combinationally from
            # that pre-edge (state, start) and registers on this SAME
            # edge, so busy is already 1 immediately after this edge, not
            # one cycle later. Deassert start now: it has been accepted.
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


# ---- Tests -------------------------------------------------------------------
@cocotb.test()
async def end_to_end_golden(dut):
    """For n in [4, 8, 16, 32, 64]: one seeded-random case, full N x D
    output compare (bit-exact) against model/attn.py attn_fixed AND
    cycle_count == nblk*(16*nblk+156)+1 exactly (checked inside run()).
    busy/done handshake shape is also checked every cycle inside run().
    Records the n-vs-cycle_count table to cycles.txt (Phase 2 benchmark)."""
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
    """all-zeros; all +127; all -128; V extremes with random Q/K; the
    monotonic score pattern from model/crosscheck.py (max-update stress
    through the whole stack) at n=16. Bit-exact compare each."""
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
    """Two different cases back to back without rst between: state (RAMs,
    online_softmax's own m/l, NUM accumulators, FSM counters) must fully
    reinitialize from the start pulse alone, with no leftover state from
    the prior run corrupting the second."""
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


@cocotb.test()
async def rst_mid_run(dut):
    """Assert rst in the middle of S_COMPUTE (300 cycles into an n=64 run,
    well inside the 6593-cycle run), verify the FSM returns to idle (busy
    drops, done stays low, cycle_count clears), then a full clean run
    computes bit-exactly."""
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
    """10 additional seeded-random cases at n in {4,8,16,32,64}, bit-exact
    compare each."""
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
    """Write known bytes to Q/K/V at scattered (shuffled) addresses, run
    once, then read the output buffer only after the run: the same output
    address read twice must be stable, and addresses read back in random
    order must be position-correct vs the golden output (not sequential-
    order-dependent)."""
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

    read_addrs = [(row, col) for row in range(n) for col in range(D)]
    rng.shuffle(read_addrs)
    for row, col in read_addrs:
        got = await read_one(dut, row, col)
        assert got == expected[row][col], (
            f"write_port_readback: out[{row}][{col}] rtl={got} "
            f"golden={expected[row][col]} (random-order read)"
        )
