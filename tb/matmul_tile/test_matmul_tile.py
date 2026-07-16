"""matmul_tile testbench: checks the RTL 4x4 output-stationary score tile
against the golden-model dot-product semantics (docs/uarch.md 8.1, the exact
SACC inner loop of model/attn.py attn_fixed: sacc = sum_d q[d] * k[j][d]).

Packing convention under test (uarch.md 8.1, little-endian slicing):
  q_flat[8*i +: 8]           = ACT element d of Q row i, i = 0..3
  k_flat[8*j +: 8]           = ACT element d of K row j, j = 0..3
  acc_flat[24*(4*i+j) +: 24] = SACC element (row i, col j), row-major

Mirror model = the mac_unit control contract (rst > clr > en priority)
applied independently to all 16 (i, j) accumulators, with 24-bit two's
complement wrap. In-spec dot products (length <= 511, uarch.md 3.2) never
wrap; the wrap test exists only to pin the register width.

Drive on RisingEdge, sample on FallingEdge (post-NBA, stable), same house
style as tb/mac_unit/test_mac_unit.py.

Seed plumbing (mandatory, carried-forward auditor finding from mac_unit):
cocotb 2.0.1 sets cocotb.RANDOM_SEED per test (regression.py hashes the test
fullname together with the COCOTB_RANDOM_SEED env var the Makefile exports)
and reseeds the global `random` module with that value before the test body
runs. Every RNG used below is built as random.Random(cocotb.RANDOM_SEED),
reading the attribute explicitly (with a fallback only if it is somehow
absent) so SEED=1 vs SEED=7 provably changes stimulus, unlike the fixed
random.Random(2)/random.Random(3) literals in tb/mac_unit which ignore the
Makefile's SEED entirely.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

ACC_W = 24
ACC_MOD = 1 << ACC_W
D = 16  # head dimension, uarch.md section 1


def wrap24(x):
    return ((x + (1 << (ACC_W - 1))) % ACC_MOD) - (1 << (ACC_W - 1))


def seeded_rng():
    """Build an RNG from cocotb's per-test seed. See module docstring."""
    seed = getattr(cocotb, "RANDOM_SEED", None)
    if seed is None:
        seed = 1  # defensive fallback only; COCOTB_RANDOM_SEED is always set
    return random.Random(seed)


def pack4(vals):
    """4 signed int8 values -> one 32-bit flat bus, element 0 in low bits."""
    flat = 0
    for idx, v in enumerate(vals):
        flat |= (v & 0xFF) << (8 * idx)
    return flat


def get_all_acc(dut):
    """Read acc_flat as one 384-bit integer and slice in Python (never rely
    on cocotb sub-signal indexing of a flat bus). Returns acc[i][j], signed."""
    val = int(dut.acc_flat.value)
    acc = [[0] * 4 for _ in range(4)]
    for i in range(4):
        for j in range(4):
            raw = (val >> (24 * (4 * i + j))) & 0xFFFFFF
            acc[i][j] = wrap24(raw)
    return acc


def golden_dot(qrows, krows):
    """Exact D-length dot products for all 16 (i, j) pairs, the same
    semantics as model/attn.py attn_fixed's SACC loop. Asserts the uarch.md
    3.2 bound |sacc| < 2^23 on every reference value."""
    g = [[0] * 4 for _ in range(4)]
    for i in range(4):
        for j in range(4):
            s = sum(q * k for q, k in zip(qrows[i], krows[j]))
            assert -(1 << 23) <= s < (1 << 23), f"golden sacc out of bound: {s}"
            g[i][j] = s
    return g


class TileMirror:
    """Bit-exact software mirror of the shared-control 4x4 grid: the
    mac_unit contract (rst > clr > en priority) applied independently to
    each of the 16 accumulators, with 24-bit wrap."""

    def __init__(self):
        self.acc = [[0] * 4 for _ in range(4)]

    def step(self, rst, en, clr, q, k):
        if rst:
            self.acc = [[0] * 4 for _ in range(4)]
            return
        new = [[0] * 4 for _ in range(4)]
        for i in range(4):
            for j in range(4):
                base = 0 if clr else self.acc[i][j]
                new[i][j] = wrap24(base + q[i] * k[j]) if en else base
        self.acc = new


async def start_and_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.en.value = 0
    dut.clr.value = 0
    dut.q_flat.value = 0
    dut.k_flat.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def assert_acc_matches(dut, expected, msg):
    got = get_all_acc(dut)
    for i in range(4):
        for j in range(4):
            assert got[i][j] == expected[i][j], (
                f"{msg}: acc({i},{j}) rtl={got[i][j]} expected={expected[i][j]}"
            )


@cocotb.test()
async def reset_and_directed(dut):
    """Reset clears all 16; a hand-computed 4x4x16 block matches exactly;
    hold with en=0; clr&&!en clears all 16."""
    await start_and_reset(dut)
    await FallingEdge(dut.clk)
    assert_acc_matches(dut, [[0] * 4 for _ in range(4)], "post-reset")

    # Hand-computed block: Q row i is the constant (i+1), K row j is the
    # constant (j+1), for all D=16 elements. dot(Q_i, K_j) = 16*(i+1)*(j+1).
    qrows = [[i + 1] * D for i in range(4)]
    krows = [[j + 1] * D for j in range(4)]
    expected = [[16 * (i + 1) * (j + 1) for j in range(4)] for i in range(4)]
    # sanity: matches the hand formula and the generic golden_dot function
    assert expected == golden_dot(qrows, krows)

    dut.en.value = 1
    for d in range(D):
        dut.q_flat.value = pack4([qrows[i][d] for i in range(4)])
        dut.k_flat.value = pack4([krows[j][d] for j in range(4)])
        dut.clr.value = 1 if d == 0 else 0
        await RisingEdge(dut.clk)
    dut.en.value = 0
    dut.clr.value = 0
    await FallingEdge(dut.clk)
    assert_acc_matches(dut, expected, "hand-computed 4x4x16 block")

    # hold: en=0, garbage data, accumulators must not move
    dut.q_flat.value = pack4([100, -100, 50, -50])
    dut.k_flat.value = pack4([100, -100, 50, -50])
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert_acc_matches(dut, expected, "hold (en=0)")

    # clr && !en clears all 16
    dut.clr.value = 1
    dut.en.value = 0
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert_acc_matches(dut, [[0] * 4 for _ in range(4)], "clr&&!en clear")
    dut.clr.value = 0


@cocotb.test()
async def golden_block_streaming(dut):
    """100 random 4x4x16 tile computations, fresh random Q/K blocks each
    trial, streamed d=0..15 with clr overlapped on d=0 back-to-back (no
    idle cycle between tiles). Full 16-element compare vs golden."""
    await start_and_reset(dut)
    rng = seeded_rng()
    for trial in range(100):
        qrows = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(4)]
        krows = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(4)]
        expected = golden_dot(qrows, krows)

        dut.en.value = 1
        for d in range(D):
            dut.q_flat.value = pack4([qrows[i][d] for i in range(4)])
            dut.k_flat.value = pack4([krows[j][d] for j in range(4)])
            dut.clr.value = 1 if d == 0 else 0
            await RisingEdge(dut.clk)
        dut.en.value = 0
        await FallingEdge(dut.clk)
        assert_acc_matches(dut, expected, f"trial {trial}")


@cocotb.test()
async def broadcast_independence(dut):
    """Directed pattern where every Q row and every K row is a distinct
    shape (not a constant), proving element (i, j) really received
    q_i . k_j and not a swapped/transposed wiring. The resulting S block
    is verified asymmetric (S[i][j] != S[j][i] for some i != j): a
    transposed acc_flat packing bug, or a swapped row/column broadcast in
    the generate block, would read back S[j][i] where S[i][j] is expected,
    which this elementwise compare catches only because the block is not
    symmetric."""
    await start_and_reset(dut)

    qrows = [
        [-6 + d for d in range(D)],
        [-6 + 2 * d for d in range(D)],
        [10 - d for d in range(D)],
        [((-1) ** d) * (d + 1) for d in range(D)],
    ]
    krows = [
        [3 * d - 20 for d in range(D)],
        [50 - 3 * d for d in range(D)],
        [((-1) ** (d + 1)) * (d + 2) for d in range(D)],
        [d - 8 for d in range(D)],
    ]
    for rows in (qrows, krows):
        for r in rows:
            assert all(-128 <= v <= 127 for v in r), r

    expected = golden_dot(qrows, krows)
    assert any(
        expected[i][j] != expected[j][i]
        for i in range(4)
        for j in range(4)
        if i != j
    ), "directed pattern must be asymmetric or this test cannot catch a transpose bug"

    dut.en.value = 1
    for d in range(D):
        dut.q_flat.value = pack4([qrows[i][d] for i in range(4)])
        dut.k_flat.value = pack4([krows[j][d] for j in range(4)])
        dut.clr.value = 1 if d == 0 else 0
        await RisingEdge(dut.clk)
    dut.en.value = 0
    dut.clr.value = 0
    await FallingEdge(dut.clk)
    assert_acc_matches(dut, expected, "broadcast independence (asymmetric block)")


@cocotb.test()
async def extremes_and_width_edges(dut):
    """All-(-128) block (max positive products), mixed +127/-128 block,
    and a negative-side accumulation edge that crosses -2^23 to pin the
    24-bit register width. In-spec D=16 dot products never wrap; only the
    dedicated wrap sub-test below intentionally over-runs D."""
    await start_and_reset(dut)

    # All-(-128): every accumulator gets the identical max-positive product
    # 16 * (-128 * -128) = 16 * 16384 = 262144.
    qrows = [[-128] * D for _ in range(4)]
    krows = [[-128] * D for _ in range(4)]
    expected = golden_dot(qrows, krows)
    dut.en.value = 1
    for d in range(D):
        dut.q_flat.value = pack4([-128, -128, -128, -128])
        dut.k_flat.value = pack4([-128, -128, -128, -128])
        dut.clr.value = 1 if d == 0 else 0
        await RisingEdge(dut.clk)
    dut.en.value = 0
    dut.clr.value = 0
    await FallingEdge(dut.clk)
    assert_acc_matches(dut, expected, "all-(-128) block")

    # Mixed +127/-128 per row/column: Q row i alternates -128/127 by parity
    # of i, K row j alternates 127/-128 by parity of j.
    qrows = [[-128 if i % 2 == 0 else 127] * D for i in range(4)]
    krows = [[127 if j % 2 == 0 else -128] * D for j in range(4)]
    expected = golden_dot(qrows, krows)
    dut.en.value = 1
    for d in range(D):
        dut.q_flat.value = pack4([qrows[i][d] for i in range(4)])
        dut.k_flat.value = pack4([krows[j][d] for j in range(4)])
        dut.clr.value = 1 if d == 0 else 0
        await RisingEdge(dut.clk)
    dut.en.value = 0
    dut.clr.value = 0
    await FallingEdge(dut.clk)
    assert_acc_matches(dut, expected, "mixed +127/-128 block")

    # Negative-side accumulation edge, single tile, no clr after the load:
    # every accumulator streams the identical product (-128)*(+127) =
    # -16256 on every enabled cycle (all 4 Q rows = -128, all 4 K rows =
    # +127, so the broadcast makes all 16 PEs identical; this is still a
    # "single accumulator" edge in the sense the mac_unit TB defines it,
    # generalized to the whole grid moving together).
    #
    # uarch.md 3.2 bound: D <= 511 in-spec, and 511*(-16256) = -8306816,
    # which is inside [-2^23, 2^23-1] = [-8388608, 8388607]. Verify that
    # exact in-spec value first.
    #
    # NOTE on the crossing count: reaching magnitude 2^23 = 8388608 needs
    # ceil(8388608 / 16256) = 517 terms (516*16256 = 8388096 is still
    # in-bound; 517*16256 = 8404352 is 15744 past the boundary and wraps).
    # So crossing takes 6 more cycles past the 511-term point, not 2; the
    # task prompt's "2 more cycles" arithmetic does not reach the boundary
    # for this operand pair, so this test uses the correct count (6) and
    # documents it here rather than weakening the check to match a wrong
    # cycle count.
    prod = -128 * 127
    dut.q_flat.value = pack4([-128, -128, -128, -128])
    dut.k_flat.value = pack4([127, 127, 127, 127])
    dut.en.value = 1
    dut.clr.value = 1
    await RisingEdge(dut.clk)
    dut.clr.value = 0
    for _ in range(510):
        await RisingEdge(dut.clk)
    dut.en.value = 0
    await FallingEdge(dut.clk)
    ref_511 = 511 * prod
    assert -(1 << 23) <= ref_511 < (1 << 23)
    expected = [[ref_511] * 4 for _ in range(4)]
    assert_acc_matches(dut, expected, "511-term negative accumulation")

    # 6 more terms: 517 total, crosses below -2^23 and wraps in 24 bits.
    dut.en.value = 1
    for _ in range(6):
        await RisingEdge(dut.clk)
    dut.en.value = 0
    await FallingEdge(dut.clk)
    ref_517 = 517 * prod
    assert ref_517 < -(1 << 23), "test setup error: 517 terms must cross -2^23"
    expected = [[wrap24(ref_517)] * 4 for _ in range(4)]
    assert_acc_matches(dut, expected, "24-bit wrap past -2^23")


@cocotb.test()
async def directed_reset_mid_tile(dut):
    """rst asserted on d=7 of a streamed tile clears all 16 accumulators
    (synchronous, takes effect the following edge); a full clean tile
    afterward computes correctly."""
    await start_and_reset(dut)
    rng = seeded_rng()

    qrows = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(4)]
    krows = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(4)]

    dut.en.value = 1
    for d in range(7):
        dut.q_flat.value = pack4([qrows[i][d] for i in range(4)])
        dut.k_flat.value = pack4([krows[j][d] for j in range(4)])
        dut.clr.value = 1 if d == 0 else 0
        await RisingEdge(dut.clk)
    dut.clr.value = 0

    # d = 7: assert rst mid-stream instead of continuing the tile
    dut.rst.value = 1
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    dut.en.value = 0
    await FallingEdge(dut.clk)
    assert_acc_matches(dut, [[0] * 4 for _ in range(4)], "rst mid-tile (d=7)")

    # a fresh, full, clean tile computes correctly after the reset
    qrows2 = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(4)]
    krows2 = [[rng.randint(-128, 127) for _ in range(D)] for _ in range(4)]
    expected = golden_dot(qrows2, krows2)
    dut.en.value = 1
    for d in range(D):
        dut.q_flat.value = pack4([qrows2[i][d] for i in range(4)])
        dut.k_flat.value = pack4([krows2[j][d] for j in range(4)])
        dut.clr.value = 1 if d == 0 else 0
        await RisingEdge(dut.clk)
    dut.en.value = 0
    dut.clr.value = 0
    await FallingEdge(dut.clk)
    assert_acc_matches(dut, expected, "clean tile after mid-tile rst")


@cocotb.test()
async def random_control_fuzz(dut):
    """2000 cycles of fully random rst/en/clr/q_flat/k_flat vs the
    16-accumulator mirror model (24-bit wrap, rst > clr > en priority),
    checked every cycle."""
    await start_and_reset(dut)
    rng = seeded_rng()
    mirror = TileMirror()
    for cycle in range(2000):
        rst = rng.random() < 0.02
        en = rng.random() < 0.7
        clr = rng.random() < 0.15
        q = [rng.randint(-128, 127) for _ in range(4)]
        k = [rng.randint(-128, 127) for _ in range(4)]
        dut.rst.value = rst
        dut.en.value = en
        dut.clr.value = clr
        dut.q_flat.value = pack4(q)
        dut.k_flat.value = pack4(k)
        await RisingEdge(dut.clk)
        mirror.step(rst, en, clr, q, k)
        await FallingEdge(dut.clk)
        got = get_all_acc(dut)
        for i in range(4):
            for j in range(4):
                assert got[i][j] == mirror.acc[i][j], (
                    f"cycle {cycle} (rst={rst} en={en} clr={clr} q={q} k={k}): "
                    f"acc({i},{j}) rtl={got[i][j]} mirror={mirror.acc[i][j]}"
                )
    dut.rst.value = 0
