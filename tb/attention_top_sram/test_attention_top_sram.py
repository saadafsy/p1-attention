"""tb/attention_top's tests, unchanged, on the macro-backed attention_top.

One difference: rd_data is sampled 9.5 ns after the edge that registers
rd_addr instead of at the falling edge. The macro drives dout from the
falling edge (OpenRAM liberty falling_edge arc; the model at 9 ns, see
tb/sram_models/sky130_sram_sim.sv), so mid-cycle the read is not valid yet;
it is valid before the next rising edge, which is what the port promises.
Report files go to this directory, tagged with RAM and PIPE_ROM.
"""

import os
import pathlib
import sys

import cocotb
from cocotb.triggers import RisingEdge, Timer

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "attention_top"))
import test_attention_top as base  # noqa: E402

TAG = os.environ.get("SRAM_TB_TAG", "sram")
base.CYCLES_PATH = HERE / f"cycles_{TAG}.txt"
base.FUNC_COV_PATH = HERE / f"func_coverage_{TAG}.txt"


async def read_one(dut, row, col):
    """Read one output byte late in the cycle after rd_addr is registered."""
    dut.rd_addr.value = (row << 4) | col
    await RisingEdge(dut.clk)
    await Timer(9500, unit="ps")
    return base.wrap8(int(dut.rd_data.value))


base.read_one = read_one

from test_attention_top import *  # noqa: E402,F401,F403  (the cocotb tests)


def _collisions(dut):
    names = ("u_qmem", "u_kmem", "u_vmem", "u_outmem")
    out = {}
    for n in names:
        ram = getattr(dut, n).u_ram
        mac = ram.g_m64 if hasattr(ram, "g_m64") else ram.g_m128
        out[n] = int(mac.u_sram.u_shim.n_collide.value)
    return out


@cocotb.test()
async def test_zzz_collision_count(dut):
    """Report same-address read-during-write cycles (their reads are poisoned)."""
    if TAG.startswith("rtl"):
        return
    dut._log.info(f"read-during-write collisions per RAM: {_collisions(dut)}")
