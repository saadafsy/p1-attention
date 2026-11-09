"""tile_runner cocotb testbench (docs/phase6_fpga_guide.md 6.3.5).

Pulses go and checks acc_flat against both the documented table and an
independent dot-product computation, so an error in either one is caught.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

D = 16  # head dimension
ACC_W = 24
ACC_MOD = 1 << ACC_W

# Q row i is constant over d; K row j at element d is (j+1)*(d+1).
Q_CODES = [1, 2, 3, -4]


def k_code(j, d):
    return (j + 1) * (d + 1)


def golden_dot():
    """Exact dot products for all 16 (i, j) pairs, asserting |sacc| < 2^23."""
    g = [[0] * 4 for _ in range(4)]
    for i in range(4):
        for j in range(4):
            s = sum(Q_CODES[i] * k_code(j, d) for d in range(D))
            assert -(1 << 23) <= s < (1 << 23), f"golden sacc out of bound: {s}"
            g[i][j] = s
    return g


# Documented table from guide 6.3.5 and fpga/tile_runner.sv.
EXPECTED_TABLE = {
    (0, 0): 136, (0, 1): 272, (0, 2): 408, (0, 3): 544,
    (1, 0): 272, (1, 1): 544, (1, 2): 816, (1, 3): 1088,
    (2, 0): 408, (2, 1): 816, (2, 2): 1224, (2, 3): 1632,
    (3, 0): -544, (3, 1): -1088, (3, 2): -1632, (3, 3): -2176,
}


def wrap24(x):
    return ((x + (1 << (ACC_W - 1))) % ACC_MOD) - (1 << (ACC_W - 1))


def get_all_acc(dut):
    """Slice the 384-bit acc_flat in Python into signed acc[i][j]."""
    val = int(dut.acc_flat.value)
    acc = [[0] * 4 for _ in range(4)]
    for i in range(4):
        for j in range(4):
            raw = (val >> (24 * (4 * i + j))) & 0xFFFFFF
            acc[i][j] = wrap24(raw)
    return acc


async def start_and_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.go.value = 0
    dut.clr.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def playback_matches_documented_and_independent_golden(dut):
    """Cross-check table vs computation, run the playback, compare, then clr."""
    await start_and_reset(dut)

    computed = golden_dot()
    for i in range(4):
        for j in range(4):
            assert computed[i][j] == EXPECTED_TABLE[(i, j)], (
                f"self-check: documented table disagrees with the "
                f"independent dot product at ({i},{j}): "
                f"table={EXPECTED_TABLE[(i, j)]} computed={computed[i][j]}"
            )

    await FallingEdge(dut.clk)
    assert not bool(dut.done.value), "done must be low before go is ever pulsed"

    dut.go.value = 1
    await RisingEdge(dut.clk)
    dut.go.value = 0

    for _ in range(20):  # 16-cycle playback + margin
        await RisingEdge(dut.clk)
        if bool(dut.done.value):
            break
    else:
        raise TimeoutError("tile_runner: done never asserted within 20 cycles of go")

    await FallingEdge(dut.clk)
    assert bool(dut.done.value), "done must be (and stay) high once the playback finishes"

    got = get_all_acc(dut)
    for i in range(4):
        for j in range(4):
            assert got[i][j] == EXPECTED_TABLE[(i, j)], (
                f"tile_runner acc({i},{j}): rtl={got[i][j]} "
                f"documented={EXPECTED_TABLE[(i, j)]}"
            )
            assert got[i][j] == computed[i][j], (
                f"tile_runner acc({i},{j}): rtl={got[i][j]} "
                f"independent-golden={computed[i][j]}"
            )
    dut._log.info(f"tile_runner playback matches documented + independent golden: {got}")

    # clr in R_DONE zeroes the accumulators and returns to R_IDLE.
    dut.clr.value = 1
    await RisingEdge(dut.clk)
    dut.clr.value = 0
    await FallingEdge(dut.clk)
    assert not bool(dut.done.value), "clr in R_DONE must drop done (back to R_IDLE)"
    got_cleared = get_all_acc(dut)
    for i in range(4):
        for j in range(4):
            assert got_cleared[i][j] == 0, f"clr must zero acc({i},{j}), got {got_cleared[i][j]}"
