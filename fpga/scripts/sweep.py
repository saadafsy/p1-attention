#!/usr/bin/env python3
"""Clock sweep on the board (Basys 3 default, or Nexys A7; change 2, step 5): for each
target frequency, rebuild the bitstream with MMCM parameters that produce
it, program the board, run the self-checking host test
(fpga/host/attn_host.py, output compared against model/attn.py), and record
one CSV row. The last frequency at which the golden compare PASSES on the
board is the MEASURED maximum; Vivado's WNS is recorded beside it but is a
tool number, not the measurement.

Usage (from the repo root, Vivado on PATH, board on PORT):
  python3 fpga/scripts/sweep.py --port /dev/ttyUSB1 --freqs 50,75,100,110,125,140
Writes build/fpga/sweep.csv with columns:
  freq_mhz, mult, divclk, out_div, vivado_wns_ns, bitstream_built,
  programmed, hw_test, n_len, seed
Rows with bitstream_built=0 are timing failures at that frequency; they are
recorded but never programmed (a failing-timing bitstream is not "working").

MMCM parameters: VCO fixed at 1000 MHz (100 MHz * 10 / 1), so
f = 1000 / CLKOUT0_DIVIDE_F with CLKOUT0_DIVIDE_F in 0.125 steps in
[2.0, 128.0]. Only frequencies representable that way are accepted.

UNVERIFIED: written without Vivado or a board.
"""
import argparse
import csv
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
VCO_MHZ = 1000.0
MULT, DIVCLK = 10, 1


def out_div_for(freq_mhz):
    d = VCO_MHZ / freq_mhz
    d8 = round(d * 8) / 8.0
    if abs(d8 - d) > 1e-9 or not (2.0 <= d8 <= 128.0):
        raise ValueError(f"{freq_mhz} MHz is not 1000/(k/8) for a legal k; nearest is {VCO_MHZ / d8:.3f}")
    return d8


def run(cmd, log):
    with open(log, "w") as f:
        r = subprocess.run(cmd, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT, text=True)
    return r.returncode


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", required=True)
    ap.add_argument("--freqs", default="50,75,100,110,125")
    ap.add_argument("--n", type=int, default=16)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default=str(ROOT / "build" / "fpga"))
    ap.add_argument("--board", default="basys3", choices=["basys3", "nexys_a7"])
    a = ap.parse_args()
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    csv_path = out / "sweep.csv"
    rows = []
    for f_str in a.freqs.split(","):
        f = float(f_str)
        od = out_div_for(f)
        clk_hz = int(round(VCO_MHZ * 1e6 / od))
        d = out / f"f{f_str.replace('.', 'p')}"
        d.mkdir(exist_ok=True)
        row = {"freq_mhz": f, "mult": MULT, "divclk": DIVCLK, "out_div": od,
               "vivado_wns_ns": "", "bitstream_built": 0, "programmed": 0,
               "hw_test": "not run", "n_len": a.n, "seed": a.seed}
        rc = run(["vivado", "-mode", "batch", "-source", "fpga/scripts/build.tcl", "-tclargs",
                  str(d), str(MULT), str(DIVCLK), str(od), str(clk_hz), a.board], d / "build.log")
        summ = d / "summary.txt"
        if summ.exists():
            for line in summ.read_text().splitlines():
                if line.startswith("setup WNS"):
                    row["vivado_wns_ns"] = line.split()[-1]
        if rc == 0 and (d / "nexys_a7_top.bit").exists():
            row["bitstream_built"] = 1
            rc = run(["vivado", "-mode", "batch", "-source", "fpga/scripts/program.tcl",
                      "-tclargs", str(d / "nexys_a7_top.bit")], d / "program.log")
            if rc == 0:
                row["programmed"] = 1
                rc = run([sys.executable, "fpga/host/attn_host.py", "--port", a.port,
                          "--n", str(a.n), "--seed", str(a.seed)], d / "hw_test.log")
                row["hw_test"] = "PASS" if rc == 0 else "FAIL"
        rows.append(row)
        print(f"{f:7.2f} MHz: built={row['bitstream_built']} programmed={row['programmed']} "
              f"hw_test={row['hw_test']} WNS={row['vivado_wns_ns']}")
    with open(csv_path, "w", newline="") as fcsv:
        w = csv.DictWriter(fcsv, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    passing = [r["freq_mhz"] for r in rows if r["hw_test"] == "PASS"]
    print(f"sweep table: {csv_path}")
    if passing:
        print(f"MEASURED maximum passing frequency on hardware: {max(passing)} MHz "
              f"(last PASS in the sweep; the tool WNS column is not a measurement)")
    else:
        print("no frequency passed on hardware; nothing is measured")
    # The sweep is a gate: no passing row, no measurement, nonzero exit
    # (make -C fpga hw-gate must not print PASS on an empty result).
    return 0 if passing else 1


if __name__ == "__main__":
    sys.exit(main())
