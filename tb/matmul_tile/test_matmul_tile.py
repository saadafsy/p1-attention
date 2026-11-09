"""matmul_tile cocotb testbench (docs/uarch.md 8.1): 4x4 output-stationary score tile.

Packing: q_flat[8*i +: 8], k_flat[8*j +: 8], acc_flat[24*(4*i+j) +: 24].
Mirror: mac_unit contract (rst > clr > en) on all 16 accumulators, 24-bit wrap.
Drives on RisingEdge, samples on FallingEdge; RNGs seed from cocotb.RANDOM_SEED.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

ACC_W = 24
ACC_MOD = 1 << ACC_W
D = 16  # head dimension


def wrap24(x):
    return ((x + (1 << (ACC_W - 1))) % ACC_MOD) - (1 << (ACC_W - 1))


def seeded_rng():
    """RNG seeded from cocotb's per-test seed."""
    seed = getattr(cocotb, "RANDOM_SEED", None)
    if seed is None:
        seed = 1
    return random.Random(seed)


def pack4(vals):
    """4 signed int8 values -> one 32-bit flat bus, element 0 in low bits."""
    flat = 0
    for idx, v in enumerate(vals):
        flat |= (v & 0xFF) << (8 * idx)
    return flat


def get_all_acc(dut):
    """Slice the 384-bit acc_flat in Python into signed acc[i][j]."""
    val = int(dut.acc_flat.value)
    acc = [[0] * 4 for _ in range(4)]
    for i in range(4):
        for j in range(4):
            raw = (val >> (24 * (4 * i + j))) & 0xFFFFFF
            acc[i][j] = wrap24(raw)
    return acc


def golden_dot(qrows, krows):
    """Exact dot products for all 16 (i, j) pairs, asserting |sacc| < 2^23."""
    g = [[0] * 4 for _ in range(4)]
    for i in range(4):
        for j in range(4):
            s = sum(q * k for q, k in zip(qrows[i], krows[j]))
            assert -(1 << 23) <= s < (1 << 23), f"golden sacc out of bound: {s}"
            g[i][j] = s
    return g


class TileMirror:
    """Bit-exact mirror of the shared-control 4x4 accumulator grid."""

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
    """Reset, a hand-computed block, hold with en=0, and clr&&!en clear."""
    await start_and_reset(dut)
    await FallingEdge(dut.clk)
    assert_acc_matches(dut, [[0] * 4 for _ in range(4)], "post-reset")

    # Q row i = (i+1), K row j = (j+1): dot = 16*(i+1)*(j+1).
    qrows = [[i + 1] * D for i in range(4)]
    krows = [[j + 1] * D for j in range(4)]
    expected = [[16 * (i + 1) * (j + 1) for j in range(4)] for i in range(4)]
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

    dut.q_flat.value = pack4([100, -100, 50, -50])
    dut.k_flat.value = pack4([100, -100, 50, -50])
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert_acc_matches(dut, expected, "hold (en=0)")

    dut.clr.value = 1
    dut.en.value = 0
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert_acc_matches(dut, [[0] * 4 for _ in range(4)], "clr&&!en clear")
    dut.clr.value = 0


@cocotb.test()
async def golden_block_streaming(dut):
    """100 random tiles back to back, clr overlapped on d=0."""
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
    """Distinct Q/K rows give an asymmetric S block, so a transposed wiring is caught."""
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
    """All-(-128) and mixed +127/-128 blocks, then a -2^23 crossing to pin 24 bits."""
    await start_and_reset(dut)

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

    # Every PE accumulates -16256; 511 terms stay in bound, 517 is the first past -2^23.
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
    """Synchronous rst on d=7 clears all 16; a clean tile follows."""
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

    dut.rst.value = 1
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    dut.en.value = 0
    await FallingEdge(dut.clk)
    assert_acc_matches(dut, [[0] * 4 for _ in range(4)], "rst mid-tile (d=7)")

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
    """2000 cycles of random control and data vs the mirror, checked every cycle."""
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
