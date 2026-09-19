#!/usr/bin/env python3
"""Prove the Perl ports of gen_gls_vectors and toggle_count agree with the
Python originals byte for byte (`make perl-crosscheck`).

1. gen_gls_vectors: Python generates build/perl-crosscheck/gls_stim.hex plus
   its two expected files; Perl consumes the SAME stimulus and writes its
   two expected files into a sibling directory; the pairs are compared.
   (Python's Mersenne-Twister stream is not reproducible from Perl, so the
   stimulus is shared, and what is proven is that both spec mirrors agree
   on every one of the 549 cycles, both latencies.)
2. toggle_count: a small deterministic synthetic VCD (scalars, vectors,
   x/z edges, width growth) is written here, both counters are run on it,
   and their stdout is compared. The GLS VCDs themselves are not needed, so
   this runs in CI without the PDK.

Exit 0 only if both comparisons match.
"""
import filecmp
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "perl-crosscheck"
PY = sys.executable or "python3"


def run(cmd, **kw):
    print("$", " ".join(str(c) for c in cmd))
    return subprocess.run(cmd, check=True, cwd=ROOT, capture_output=True, text=True, **kw)


def synthetic_vcd(path):
    lines = [
        "$timescale 1ns $end", "$scope module gls_tb $end", "$scope module dut $end",
        "$var wire 1 ! clk $end", "$var wire 1 \" rst $end", "$var wire 16 # w [15:0] $end",
        "$var wire 24 $ l [23:0] $end", "$var wire 1 % out_valid $end",
        "$upscope $end", "$upscope $end", "$enddefinitions $end",
        "$dumpvars", "x!", "x\"", "bx #", "b0 $", "0%", "$end",
    ]
    t = 0
    for i in range(1, 200):
        t += 5
        lines.append(f"#{t}")
        lines.append(f"{i % 2}!")
        if i == 3:
            lines.append("1\"")
        if i == 6:
            lines.append("0\"")
        if i >= 6:
            lines.append(f"b{bin((i * 2654435761) & 0xFFFF)[2:]} #")   # unpadded, width varies
            lines.append(f"b{bin((i * 40503) & 0xFFFFFF)[2:]} $")
            lines.append(f"{(i // 3) % 2}%")
        if i == 100:
            lines.append("bz #")            # z edge must be ignored
    path.write_text("\n".join(lines) + "\n")


def main():
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "py").mkdir(parents=True)
    (OUT / "pl").mkdir(parents=True)

    run([PY, "scripts/gen_gls_vectors.py", "--out-dir", str(OUT / "py")])
    run(["perl", "scripts/gen_gls_vectors.pl", "--stim", str(OUT / "py" / "gls_stim.hex"),
         "--out-dir", str(OUT / "pl")])
    ok = True
    for fn in ("gls_expected_lat1.hex", "gls_expected_lat2.hex"):
        same = filecmp.cmp(OUT / "py" / fn, OUT / "pl" / fn, shallow=False)
        print(f"{fn}: {'IDENTICAL' if same else 'DIFFER'}")
        ok &= same

    vcd_a = OUT / "synthetic_a.vcd"
    vcd_b = OUT / "synthetic_b.vcd"
    synthetic_vcd(vcd_a)
    synthetic_vcd(vcd_b)
    py_out = run([PY, "scripts/toggle_count.py", str(vcd_a), str(vcd_b)]).stdout
    pl_out = run(["perl", "scripts/toggle_count.pl", str(vcd_a), str(vcd_b)]).stdout
    (OUT / "toggle_py.txt").write_text(py_out)
    (OUT / "toggle_pl.txt").write_text(pl_out)
    same = py_out == pl_out
    print(f"toggle_count stdout: {'IDENTICAL' if same else 'DIFFER'}")
    if not same:
        print("--- python ---\n" + py_out + "--- perl ---\n" + pl_out)
    ok &= same

    print("PERL CROSSCHECK PASS" if ok else "PERL CROSSCHECK FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
