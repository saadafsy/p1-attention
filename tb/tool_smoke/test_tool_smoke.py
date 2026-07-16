"""Phase -1 smoke test: resettable counter vs a trivial Python golden model.

Drives inputs after the rising edge, checks state on the falling edge, so
sampled values are post-NBA and stable under both Verilator and Icarus.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

WIDTH = 8
MASK = (1 << WIDTH) - 1


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


async def reset(dut):
    dut.rst.value = 1
    dut.en.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def count_and_hold(dut):
    """Counts when en=1, holds when en=0, resets to 0."""
    await start_clock(dut)
    await reset(dut)
    await FallingEdge(dut.clk)
    assert dut.count.value == 0, f"post-reset count={int(dut.count.value)}"

    # count 5
    dut.en.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert dut.count.value == 5, f"count={int(dut.count.value)} expected 5"

    # hold 3
    dut.en.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert dut.count.value == 5, f"hold broke: count={int(dut.count.value)}"

    # mid-run reset wins over en
    dut.en.value = 1
    dut.rst.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert dut.count.value == 0, f"reset failed: count={int(dut.count.value)}"
    dut.rst.value = 0


@cocotb.test()
async def wraparound(dut):
    """Counter wraps modulo 2**WIDTH."""
    await start_clock(dut)
    await reset(dut)
    dut.en.value = 1
    for _ in range((1 << WIDTH) + 3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert dut.count.value == 3, f"wrap: count={int(dut.count.value)} expected 3"


@cocotb.test()
async def random_stimulus_vs_model(dut):
    """200 cycles of random rst/en checked against a golden model every cycle."""
    await start_clock(dut)
    await reset(dut)
    model = 0
    for cycle in range(200):
        rst = random.random() < 0.1
        en = random.random() < 0.7
        dut.rst.value = rst
        dut.en.value = en
        await RisingEdge(dut.clk)
        if rst:
            model = 0
        elif en:
            model = (model + 1) & MASK
        await FallingEdge(dut.clk)
        got = int(dut.count.value)
        assert got == model, f"cycle {cycle}: rtl={got} model={model}"
