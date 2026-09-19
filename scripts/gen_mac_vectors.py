#!/usr/bin/env python3
"""Golden vectors for mac_unit (both the SystemVerilog and the VHDL port),
and the checker for traces the replay testbench writes (tb/vhdl_mac).

Mirror: the mac_unit control contract (docs/uarch.md 8.1 row table) with
24-bit two's-complement wrap, the same semantics as tb/mac_unit's MacMirror
and the SACC loop of model/attn.py. One line per clock edge:
  rst en clr a b acc      (a, b signed int8; acc signed 24-bit AFTER the edge)

  --emit SEED OUT     constrained-random stimulus + expected acc
  --check TRACE       recompute expected over a trace's stimulus columns and
                      diff against its acc column; exit 1 on mismatch
"""
import argparse
import random
import sys

ACC_MOD = 1 << 24
EDGES = [-128, -64, -1, 0, 1, 63, 127]


def wrap24(x):
    return ((x + (1 << 23)) % ACC_MOD) - (1 << 23)


def step(acc, rst, en, clr, a, b):
    if rst:
        return 0
    base = 0 if clr else acc
    return wrap24(base + a * b) if en else base


def rand_act(rng):
    return rng.choice(EDGES) if rng.random() < 0.4 else rng.randint(-128, 127)


def emit(seed, path, dots=300):
    rng = random.Random(seed)
    acc = 0
    lines = ["# rst en clr a b acc_after_edge   (scripts/gen_mac_vectors.py --emit %d)" % seed]

    def push(rst, en, clr, a, b):
        nonlocal acc
        acc = step(acc, rst, en, clr, a, b)
        lines.append(f"{rst} {en} {clr} {a} {b} {acc}")

    push(1, 0, 0, 0, 0)
    push(1, 0, 0, 0, 0)
    push(0, 0, 0, 0, 0)
    for _ in range(dots):
        for d in range(16):
            if d > 0 and rng.random() < 0.08:
                push(0, 0, 0, rand_act(rng), rand_act(rng))
            push(0, 1, 1 if d == 0 else 0, rand_act(rng), rand_act(rng))
        r = rng.random()
        if r < 0.1:
            push(0, 0, 1, 0, 0)
        elif r < 0.15:
            push(1, 0, 0, rand_act(rng), rand_act(rng))
        elif r < 0.4:
            for _ in range(rng.randint(1, 3)):
                push(0, 0, 0, rand_act(rng), rand_act(rng))
    # the in-spec width edge: 511 max-magnitude terms, exact (uarch.md 3.2)
    push(0, 1, 1, -128, -128)
    for _ in range(510):
        push(0, 1, 0, -128, -128)
    push(0, 0, 0, 0, 0)
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {path}: {len(lines) - 1} cycles")


def check(path):
    acc = 0
    n = bad = 0
    for lineno, raw in enumerate(open(path), 1):
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        v = [int(x) for x in s.split()]
        if len(v) != 6:
            print(f"{path}:{lineno}: expected 6 columns, got {len(v)}")
            return 1
        rst, en, clr, a, b, got = v
        acc = step(acc, rst, en, clr, a, b)
        n += 1
        if got != acc:
            bad += 1
            if bad <= 10:
                print(f"{path}:{lineno}: MISMATCH rst={rst} en={en} clr={clr} a={a} b={b}: dut={got} ref={acc}")
    print(f"checked {n} cycles: {'PASS' if bad == 0 else f'FAIL ({bad} mismatches)'}")
    return 0 if bad == 0 and n > 0 else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--emit", nargs=2, metavar=("SEED", "OUT"))
    ap.add_argument("--dots", type=int, default=300)
    ap.add_argument("--check", metavar="TRACE")
    a = ap.parse_args()
    if a.emit:
        emit(int(a.emit[0]), a.emit[1], a.dots)
        return 0
    if a.check:
        return check(a.check)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
