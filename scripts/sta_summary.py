#!/usr/bin/env python3
"""Summarize an OpenSTA report_checks log (scripts/sta.tcl output) into the
numbers a claim needs: worst setup slack (WNS), worst hold slack, the worst
path's startpoint/endpoint, and which block of attention_top owns the path,
classified from the hierarchical instance names in the path.

Added 2026-09-19 (target-scores change 3, top-level STA). Exit 1 if no
slack/startpoint/endpoint can be found, so an empty or errored report can
never be summarized as a result.

Usage: python3 scripts/sta_summary.py build/sta_attention_top.log \\
           --period 10 --out build/sta_attention_top_summary.txt
"""
import argparse
import re
import sys
from pathlib import Path

# Hierarchy prefixes -> owning block, for attention_top's netlist. Order
# matters: the first match wins.
BLOCKS = [
    (r"u_tile", "matmul_tile (Q.K^T MAC array)"),
    (r"u_sm|g_softmax", "online_softmax lane (max/LUT/rescale recurrence)"),
    (r"g_pv|pva_|acc_num|lsel|rs_d", "shared PV datapath / NUM accumulators"),
    (r"g_div|qt_reg|rem_reg|abs_a_reg|row_c", "divider bank"),
    (r"u_qmem|u_kmem|u_vmem|u_outmem|q_flat|k_flat|v_row_reg|rd_col_q|rd_data", "memory pins (SRAM stand-in) and read paths"),
    (r"drain_buf|s_conv|s_shift", "drain buffer / score conversion"),
    (r"\b(state|rg|kb|t|row|div_cnt|cycle_count|nblk_reg|done)\b", "FSM / counters"),
]


def flop_nets(netlist):
    """Map flip-flop instance name -> its Q net name. Flattened yosys
    netlists give cells anonymous names (_123_), but the register's net
    keeps the RTL name, which is what identifies the block."""
    nets = {}
    cell = None
    for line in Path(netlist).read_text(errors="replace").splitlines():
        m = re.match(r"\s*sky130_fd_sc_hd__df\w*\s+(\S+)\s*\(", line)
        if m:
            cell = m.group(1)
            continue
        if cell:
            m = re.search(r"\.Q\((.+)\)", line)
            if m:
                nets[cell] = m.group(1).strip()
                cell = None
            elif line.strip().startswith(");"):
                cell = None
    return nets


def parse(text):
    """Return list of (kind, startpoint, endpoint, slack, path_lines) for
    each report_checks path block. kind is 'max' (setup) or 'min' (hold),
    decided by the '---HOLD-CHECK---' marker sta.tcl prints between them."""
    paths = []
    kind = "max"
    cur = None
    for line in text.splitlines():
        if "---HOLD-CHECK---" in line:
            kind = "min"
            continue
        m = re.match(r"\s*Startpoint:\s*(\S+)", line)
        if m:
            cur = {"kind": kind, "start": m.group(1), "end": None, "slack": None, "lines": []}
            paths.append(cur)
            continue
        if cur is None:
            continue
        cur["lines"].append(line)
        m = re.match(r"\s*Endpoint:\s*(\S+)", line)
        if m:
            cur["end"] = m.group(1)
        m = re.match(r"\s*(-?\d+\.\d+)\s+slack\s+\((MET|VIOLATED)\)", line)
        if m:
            cur["slack"] = float(m.group(1))
    return [p for p in paths if p["slack"] is not None and p["end"]]


def owner(names):
    """Classify by the start/end register (net) names, startpoint first."""
    for text in names:
        for pat, name in BLOCKS:
            if re.search(pat, text):
                return name
    return "unclassified (inspect the path)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--period", type=float, required=True)
    ap.add_argument("--out")
    ap.add_argument("--netlist", help="gate netlist, to name anonymous flops by their Q net")
    a = ap.parse_args()
    nets = flop_nets(a.netlist) if a.netlist else {}
    name = lambda c: f"{c} ({nets[c]})" if c in nets else c
    text = Path(a.log).read_text(errors="replace")
    paths = parse(text)
    setup = [p for p in paths if p["kind"] == "max"]
    hold = [p for p in paths if p["kind"] == "min"]
    if not setup:
        print("sta_summary: no setup path with slack/startpoint/endpoint found in", a.log)
        return 1
    worst = min(setup, key=lambda p: p["slack"])
    lines = [
        "# attention_top STA summary (pre-layout standard-cell estimate, sky130 tt; the four",
        "# memories are SRAM-macro stand-ins: flops at the macro pins, macro access time not modeled)",
        f"source: {a.log}",
        f"clock period: {a.period} ns",
        f"setup WNS: {worst['slack']:+.3f} ns ({'MET' if worst['slack'] >= 0 else 'VIOLATED'})",
        f"implied Fmax at this WNS: {1000.0 / (a.period - min(worst['slack'], 0.0)):.1f} MHz "
        "(1/(period - WNS) when violated; tool estimate)",
        f"worst setup path: {name(worst['start'])} -> {name(worst['end'])}",
        f"owning block: {owner([nets.get(worst['start'], worst['start']), nets.get(worst['end'], worst['end'])])}",
    ]
    if hold:
        wh = min(hold, key=lambda p: p["slack"])
        lines.append(f"hold worst slack: {wh['slack']:+.3f} ns ({'MET' if wh['slack'] >= 0 else 'VIOLATED'}), "
                     f"{name(wh['start'])} -> {name(wh['end'])}")
    lines.append("")
    lines.append("worst setup path detail:")
    lines += ["  " + l for l in worst["lines"]]
    out = "\n".join(lines) + "\n"
    print(out)
    if a.out:
        Path(a.out).write_text(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
