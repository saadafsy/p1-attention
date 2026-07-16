"""mac_unit testbench: checks the RTL against the golden-model MAC semantics
(docs/uarch.md 3.1/3.2, the exact inner loop of model/attn.py attn_fixed).

Mirror model = the normative control contract with 24-bit two's complement
wrap. In-spec dot products (length <= 511) never wrap (uarch.md 3.2); the
wrap tests exist to pin the register width, not to bless overflow as a
feature.

Drive on RisingEdge, sample on FallingEdge (post-NBA, stable)."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

ACC_W = 24
ACC_MOD = 1 << ACC_W
ACC_MAX = (1 << (ACC_W - 1)) - 1


def wrap24(x):
    return ((x + (1 << (ACC_W - 1))) % ACC_MOD) - (1 << (ACC_W - 1))


def acc_signed(dut):
    return wrap24(int(dut.acc.value))


class MacMirror:
    """Bit-exact software mirror of the mac_unit control contract."""

    def __init__(self):
        self.acc = 0

    def step(self, rst, en, clr, a, b):
        if rst:
            self.acc = 0
        else:
            base = 0 if clr else self.acc
            self.acc = wrap24(base + a * b) if en else base


async def start_and_reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.en.value = 0
    dut.clr.value = 0
    dut.a.value = 0
    dut.b.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def reset_and_directed(dut):
    """Reset clears; directed checks of every control combination."""
    await start_and_reset(dut)
    await FallingEdge(dut.clk)
    assert acc_signed(dut) == 0, "acc != 0 after reset"

    # clr+en loads first product: 3 * -5 (Q1.6 raws)
    dut.a.value = 3
    dut.b.value = -5
    dut.clr.value = 1
    dut.en.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert acc_signed(dut) == -15, f"load: {acc_signed(dut)} != -15"

    # accumulate: + (-7 * -9) = +63 -> 48
    dut.a.value = -7
    dut.b.value = -9
    dut.clr.value = 0
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert acc_signed(dut) == 48, f"acc: {acc_signed(dut)} != 48"

    # hold
    dut.en.value = 0
    dut.a.value = 100
    dut.b.value = 100
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert acc_signed(dut) == 48, f"hold broke: {acc_signed(dut)}"

    # clr without en clears
    dut.clr.value = 1
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    assert acc_signed(dut) == 0, f"clr/!en: {acc_signed(dut)} != 0"
    dut.clr.value = 0


@cocotb.test()
async def dot_products_vs_golden(dut):
    """200 random D=16 dot products, exactly the golden model's SACC loop
    (model/attn.py attn_fixed inner loop), back to back with no dead cycle."""
    await start_and_reset(dut)
    rng = random.Random(2)
    for trial in range(200):
        qv = [rng.randint(-128, 127) for _ in range(16)]
        kv = [rng.randint(-128, 127) for _ in range(16)]
        ref = sum(q * k for q, k in zip(qv, kv))  # exact, as in attn.py
        assert -(1 << 23) <= ref < (1 << 23)      # uarch.md 3.2 bound

        for d in range(16):
            dut.a.value = qv[d]
            dut.b.value = kv[d]
            dut.en.value = 1
            dut.clr.value = 1 if d == 0 else 0    # back-to-back restart
            await RisingEdge(dut.clk)
        dut.en.value = 0
        await FallingEdge(dut.clk)
        got = acc_signed(dut)
        assert got == ref, f"trial {trial}: rtl={got} golden={ref}"


@cocotb.test()
async def extremes_and_width_edge(dut):
    """Extreme operands, the 511-term no-overflow bound, and 24-bit wrap."""
    await start_and_reset(dut)

    # all corner operand pairs, one-shot loads
    for a in (-128, -1, 0, 1, 127):
        for b in (-128, -1, 0, 1, 127):
            dut.a.value = a
            dut.b.value = b
            dut.en.value = 1
            dut.clr.value = 1
            await RisingEdge(dut.clk)
            dut.en.value = 0
            await FallingEdge(dut.clk)
            assert acc_signed(dut) == a * b, f"{a}*{b}: {acc_signed(dut)}"

    # 511 max-magnitude products: largest in-spec accumulation, must be exact
    dut.a.value = -128
    dut.b.value = -128
    dut.en.value = 1
    dut.clr.value = 1
    await RisingEdge(dut.clk)
    dut.clr.value = 0
    for _ in range(510):
        await RisingEdge(dut.clk)
    dut.en.value = 0
    await FallingEdge(dut.clk)
    assert acc_signed(dut) == 511 * 16384, \
        f"511-term: {acc_signed(dut)} != {511 * 16384}"

    # one more term wraps: pins the register at exactly 24 bits
    dut.en.value = 1
    await RisingEdge(dut.clk)
    dut.en.value = 0
    await FallingEdge(dut.clk)
    assert acc_signed(dut) == wrap24(512 * 16384), \
        f"wrap: {acc_signed(dut)} != {wrap24(512 * 16384)}"


@cocotb.test()
async def random_control_fuzz(dut):
    """2000 cycles of fully random data and control vs the mirror, checked
    every cycle (catches en/clr priority and hold bugs)."""
    await start_and_reset(dut)
    rng = random.Random(3)
    mirror = MacMirror()
    for cycle in range(2000):
        rst = rng.random() < 0.02
        en = rng.random() < 0.7
        clr = rng.random() < 0.15
        a = rng.randint(-128, 127)
        b = rng.randint(-128, 127)
        dut.rst.value = rst
        dut.en.value = en
        dut.clr.value = clr
        dut.a.value = a
        dut.b.value = b
        await RisingEdge(dut.clk)
        mirror.step(rst, en, clr, a, b)
        await FallingEdge(dut.clk)
        got = acc_signed(dut)
        assert got == mirror.acc, \
            f"cycle {cycle} (rst={rst} en={en} clr={clr} a={a} b={b}): " \
            f"rtl={got} mirror={mirror.acc}"
    dut.rst.value = 0
