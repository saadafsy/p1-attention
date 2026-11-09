"""sync_ram vs sync_ram_sky130 (OpenRAM model), cycle by cycle on random traffic.

Both RAMs see the same inputs every cycle. Inputs change right after the
rising edge; outputs are compared 9.5 ns into the next cycle (the macro's
dout is valid 9 ns after the edge, see tb/sram_models/sky130_sram_sim.sv).
A cycle that writes and reads the same address is undefined on the macro:
there the wrapper must show the shim's POISON and the compare is skipped.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

N_CYCLES = 20000


class Port:
    def __init__(self, dut, tag, aw, dw):
        self.dut, self.aw, self.dw, self.nb = dut, aw, dw, dw // 8
        self.we = getattr(dut, f"we_{tag}")
        self.be = getattr(dut, f"be_{tag}")
        self.waddr = getattr(dut, f"waddr_{tag}")
        self.wdata = getattr(dut, f"wdata_{tag}")
        self.raddr = getattr(dut, f"raddr_{tag}")
        self.ref = getattr(dut, f"ref_{tag}")
        self.mac = getattr(dut, f"mac_{tag}")
        self.poison = int("A5" * self.nb, 16)
        self.recent = [0]
        self.stats = {"compared": 0, "collide": 0, "rst": 0}

    def drive(self, we, be, waddr, wdata, raddr):
        self.we.value, self.be.value, self.waddr.value = we, be, waddr
        self.wdata.value, self.raddr.value = wdata, raddr
        return bool(we and be and waddr == raddr)

    def random_cycle(self, rng):
        we = int(rng.random() < 0.5)
        be = rng.choice([(1 << self.nb) - 1, 0, rng.getrandbits(self.nb), 1 << rng.randrange(self.nb)])
        waddr = rng.randrange(1 << self.aw)
        r = rng.random()
        if r < 0.05:
            raddr = waddr  # same-cycle collision (undefined on the macro)
        elif r < 0.35:
            raddr = rng.choice(self.recent)  # read after a recent write
        else:
            raddr = rng.randrange(1 << self.aw)
        if we and be:
            self.recent = (self.recent + [waddr])[-8:]
        return self.drive(we, be, waddr, rng.getrandbits(self.dw), raddr)

    def check(self, collided, in_rst, cyc):
        ref, mac = int(self.ref.value), int(self.mac.value)
        if in_rst:
            self.stats["rst"] += 1
            assert ref == 0 and mac == 0, f"cyc {cyc}: rdata after reset ref={ref:x} mac={mac:x}"
        elif collided:
            self.stats["collide"] += 1
            assert mac == self.poison, f"cyc {cyc}: collision not flagged, mac={mac:x}"
            return
        assert ref == mac, f"cyc {cyc} DW={self.dw}: ref={ref:x} macro={mac:x}"
        self.stats["compared"] += 1


@cocotb.test()
async def random_traffic_equivalence(dut):
    rng = random.Random(getattr(cocotb, "RANDOM_SEED", 1) or 1)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    pa = Port(dut, "a", 8, 32)
    pb = Port(dut, "b", 6, 128)
    ports = (pa, pb)

    dut.rst.value = 1
    for p in ports:
        p.drive(0, 0, 0, 0, 0)
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    # Fill every word so both RAMs start from the same defined contents.
    for a in range(256):
        await RisingEdge(dut.clk)
        pa.drive(1, 0xF, a, rng.getrandbits(32), (a + 1) % 256)
        pb.drive(1, 0xFFFF, a % 64, rng.getrandbits(128), (a + 1) % 64)
    await RisingEdge(dut.clk)
    for p in ports:
        p.drive(0, 0, 0, 0, 0)
    await RisingEdge(dut.clk)

    # Random traffic. Each iteration: drive at the edge, then check the read
    # captured at that same edge (inputs from the previous iteration).
    prev = [(False, False)] * 2
    for cyc in range(N_CYCLES):
        await RisingEdge(dut.clk)
        in_rst = rng.random() < 0.01
        dut.rst.value = int(in_rst)
        now = [(p.random_cycle(rng), in_rst) for p in ports]
        await Timer(9500, unit="ps")
        if cyc > 0:
            for p, (col, r) in zip(ports, prev):
                p.check(col and not r, r, cyc)
        prev = now

    for p in ports:
        dut._log.info(f"DW={p.dw}: {p.stats}")
        assert p.stats["compared"] > N_CYCLES * 0.8
        assert p.stats["collide"] > 0 and p.stats["rst"] > 0


@cocotb.test()
async def directed_byte_enable_and_raw(dut):
    """Partial writes merge per byte; a read the cycle after a write sees it."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    pa = Port(dut, "a", 8, 32)
    pb = Port(dut, "b", 6, 128)
    dut.rst.value = 1
    pa.drive(0, 0, 0, 0, 0)
    pb.drive(0, 0, 0, 0, 0)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0

    seq = [  # (we, be, waddr, wdata, raddr, expected rdata next cycle or None)
        (1, 0xF, 5, 0x11223344, 0, None),
        (1, 0x2, 5, 0xAABBCCDD, 0, None),  # only byte 1
        (0, 0x0, 0, 0, 5, 0x1122CC44),
        (1, 0x8, 5, 0xEE000000, 6, None),
        (0, 0x0, 0, 0, 5, 0xEE22CC44),
        (1, 0x0, 5, 0xFFFFFFFF, 5, 0xEE22CC44),  # we with no byte enable: no write
    ]
    prev_exp = None
    for we, be, wa, wd, ra, exp in seq + [(0, 0, 0, 0, 0, None)]:
        await RisingEdge(dut.clk)
        pa.drive(we, be, wa, wd, ra)
        pb.drive(we, be << 12, wa, wd << 96, ra)
        await Timer(9500, unit="ps")
        if prev_exp is not None:  # read captured at this edge, from the previous row
            assert int(dut.ref_a.value) == int(dut.mac_a.value) == prev_exp
            assert int(dut.ref_b.value) == int(dut.mac_b.value)
            assert int(dut.mac_b.value) >> 96 == prev_exp  # lanes 12..15
        prev_exp = exp
