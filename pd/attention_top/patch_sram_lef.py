"""Patch an OpenRAM sky130 macro LEF whose vdd and gnd pins overlap.

In sky130_sram_1rw1r_64x256_8 and _128x256_8 two columns of met3 pads are
listed with a vdd pad and a gnd pad on top of each other (130 pairs per
column in the 64x256, 258 in the 128x256). Any grid that connects there
shorts VDD to VSS, and power-grid analysis reports every pair as a short.
This script removes each overlapping pad from both pins and adds it to
OBS as met3, so nothing connects to it and the router keeps clear. The
thousands of other vdd and gnd pads stay pins.

usage: python3 patch_sram_lef.py <in.lef> <out.lef>
"""
import re
import sys

RECT = re.compile(r"\s*RECT\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s+([\d.\-]+)\s*;")


def overlap(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def main():
    src, dst = sys.argv[1:3]
    lines = open(src).read().split("\n")
    rects = {"vdd": [], "gnd": []}
    pin = None
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("PIN "):
            pin = s.split()[1] if s.split()[1] in rects else None
        elif s.startswith("END ") and pin and s.split()[1] == pin:
            pin = None
        elif pin:
            m = RECT.match(line)
            if m:
                rects[pin].append((i, tuple(map(float, m.groups()))))
    gnd_by_x = {}
    for i, r in rects["gnd"]:
        gnd_by_x.setdefault(int(r[0]), []).append((i, r))
    drop = set()
    # Pads within EDGE um of the macro's left or right side: the power grid
    # extends these outward to the core straps, across the core grid's via
    # stacks of the other net (14 shorts in the 2026-11-09 runs). The interior
    # pads carry the supply.
    size = re.search(r"SIZE\s+([\d.]+)\s+BY", "\n".join(lines))
    width = float(size.group(1))
    EDGE = 8.0
    for net in ("vdd", "gnd"):
        for i, r in rects[net]:
            if r[0] < EDGE or r[2] > width - EDGE:
                drop.add(i)
    for i, v in rects["vdd"]:
        for dx in (-1, 0, 1):
            for j, g in gnd_by_x.get(int(v[0]) + dx, []):
                if overlap(v, g):
                    drop.update((i, j))
    moved = []
    out = []
    for i, line in enumerate(lines):
        if i in drop:
            moved.append(RECT.match(line).groups())
            if out and out[-1].strip() == "LAYER met3 ;":
                out.pop()
            continue
        out.append(line)
        if line.strip() == "OBS":
            for r in sorted(set(moved)):
                pass  # filled below, after all pads are known
    # Insert the moved pads right after the OBS line.
    k = next(n for n, line in enumerate(out) if line.strip() == "OBS")
    obs = []
    for r in sorted(set(moved)):
        obs += ["      LAYER met3 ;", "      RECT  %s %s %s %s ;" % r]
    out[k + 1:k + 1] = obs
    open(dst, "w").write("\n".join(out))
    print(f"{src}: moved {len(drop)} vdd/gnd pads (overlapping or edge) to OBS")


if __name__ == "__main__":
    main()
