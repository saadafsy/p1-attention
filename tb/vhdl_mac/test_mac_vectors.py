"""Replay testbench for mac_unit, language-agnostic: the same test drives
the SystemVerilog rtl/mac_unit.sv (verilator) or the VHDL
rtl_vhdl/mac_unit.vhd (GHDL), selected by the Makefile's LANG knob, with
the SAME golden vector file (scripts/gen_mac_vectors.py --emit), checks
every cycle against the file's expected acc, and writes an observed trace.
`make vhdl-crosscheck` (repo root) runs both and byte-compares the two
traces, which is the evidence that the VHDL port is equivalent to the
SystemVerilog original (target-scores change 9, added 2026-09-19).

Drive on RisingEdge, sample on FallingEdge, house style of tb/mac_unit.
Vector file: +VECTOR_FILE via the VECTOR_FILE env var (Makefile), trace
via TRACE_FILE. Never run yet (no simulator where this was written).
"""
import os
import pathlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

ACC_W = 24


def wrap24(x):
    return ((x + (1 << (ACC_W - 1))) % (1 << ACC_W)) - (1 << (ACC_W - 1))


def to_u8(v):
    return v & 0xFF


@cocotb.test()
async def replay_golden_vectors(dut):
    vec = pathlib.Path(os.environ["VECTOR_FILE"])
    trace = pathlib.Path(os.environ.get("TRACE_FILE", "trace.txt"))
    rows = []
    for raw in vec.read_text().splitlines():
        s = raw.strip()
        if s and not s.startswith("#"):
            rows.append([int(x) for x in s.split()])
    assert rows, f"{vec}: no vectors"

    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.en.value = 0
    dut.clr.value = 0
    dut.a.value = 0
    dut.b.value = 0
    await RisingEdge(dut.clk)

    out = ["# rst en clr a b acc_after_edge   (OBSERVED, tb/vhdl_mac replay)"]
    errors = 0
    for i, (rst, en, clr, a, b, exp) in enumerate(rows):
        dut.rst.value = rst
        dut.en.value = en
        dut.clr.value = clr
        dut.a.value = to_u8(a)   # unsigned bit pattern: valid for both a logic
        dut.b.value = to_u8(b)   # signed [7:0] and a std_logic_vector port
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        got = wrap24(int(dut.acc.value))
        out.append(f"{rst} {en} {clr} {a} {b} {got}")
        if got != exp:
            errors += 1
            if errors <= 10:
                dut._log.error(f"cycle {i}: rst={rst} en={en} clr={clr} a={a} b={b}: dut={got} golden={exp}")
    trace.write_text("\n".join(out) + "\n")
    dut._log.info(f"replayed {len(rows)} cycles from {vec}, {errors} mismatches, trace {trace}")
    assert errors == 0, f"{errors} mismatches against {vec}"
