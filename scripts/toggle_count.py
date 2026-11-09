#!/usr/bin/env python3
"""Count 0<->1 transitions per net in GLS VCDs (x/z ignored, one per changed vector bit).

A relative toggle proxy for two netlists on the same stimulus, not a power measurement.
Usage: python3 scripts/toggle_count.py build/gls_lat1.vcd [build/gls_lat2.vcd ...]
"""
import sys


def parse_vcd(path):
    # A net's first value (from $dumpvars) only seeds last[code], so it is never counted.
    ids = {}       # id code -> bit width
    last = {}      # id code -> last value string
    toggles = {}   # id code -> toggle count
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
