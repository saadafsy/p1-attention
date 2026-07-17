#!/usr/bin/env python3
"""Phase 5 switching-activity proxy: count logic transitions in the GLS VCDs.

Usage: python3 scripts/toggle_count.py build/gls_lat1.vcd [build/gls_lat2.vcd ...]

For each VCD (produced by make -C tb/gls all, which replays the IDENTICAL
stimulus into both PIPE_ROM netlist configs), counts 0<->1 transitions on
every dumped net in the DUT scope. x/z edges are ignored (they occur only
before reset resolves). Vector signals count one toggle per changed bit.

This is a TOGGLE-COUNT PROXY, not a power measurement: it weights every net
equally (no capacitance, no slew, no clock tree since the sandbox clock is
ideal). It is honest for RELATIVE comparison of two netlists driven by the
same stimulus through the same cell library, which is exactly the Phase 5
question (naive comb-ROM vs PIPE_ROM pipelined). Absolute power stays a
tool estimate at best until Phase 7 (OpenLane) or real hardware.
"""
import sys


def parse_vcd(path):
    ids = {}       # id code -> bit width
    last = {}      # id code -> last value string
    toggles = {}   # id code -> toggle count
    in_dumpsec = False
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("$var"):
                # $var wire 16 !"# w [15:0] $end
                parts = line.split()
                width, code = int(parts[2]), parts[3]
                ids[code] = width
                toggles.setdefault(code, 0)
            elif line.startswith("$"):
                in_dumpsec = line.startswith(("$dumpvars", "$dumpon"))
                continue
            elif line[0] == "#":
                continue
            elif line[0] in "01xz":
                code = line[1:]
                new = line[0]
                old = last.get(code)
                if old is not None and old != new and old in "01" and new in "01":
                    toggles[code] = toggles.get(code, 0) + 1
                last[code] = new
            elif line[0] in "bB":
                val, code = line[1:].split()
                old = last.get(code)
                if old is not None:
                    o = old.zfill(max(len(old), len(val)))
                    n = val.zfill(len(o))
                    for a, c in zip(o, n):
                        if a != c and a in "01" and c in "01":
                            toggles[code] = toggles.get(code, 0) + 1
                last[code] = val
    return ids, toggles


def main():
    print(f"{'vcd':<28} {'nets':>6} {'toggles':>10} {'togg/net':>9}")
    results = []
    for path in sys.argv[1:]:
        ids, toggles = parse_vcd(path)
        total = sum(toggles.values())
        results.append((path, len(ids), total))
        print(f"{path:<28} {len(ids):>6} {total:>10} {total/len(ids):>9.1f}")
    if len(results) == 2:
        a, b = results[0][2], results[1][2]
        print(f"ratio {sys.argv[2]}/{sys.argv[1]}: {b/a:.3f}")


if __name__ == "__main__":
    main()
