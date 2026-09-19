#!/usr/bin/env python3
"""Snapshot the build/ reports that EVIDENCE.md rows cite into the tracked
evidence/reports/<UTC stamp>/ directory, with a manifest of sha256 sums,
sizes, the git commit, and the tool versions found on PATH.

Why (2026-09-18, review finding F014): every timing/area/power/GLS/audit
row in EVIDENCE.md cites only files under build/, which is gitignored, so
none of the quoted numbers (slack, cell counts, toggle totals, mW) could be
inspected from a clone. Running `make evidence-snapshot` after the flow
copies the report files here; commit the directory and cite
`evidence/reports/<stamp>/<file>` (or the manifest's sha256) from the row.

Usage: python3 scripts/evidence_snapshot.py [--build build] [--out evidence/reports]
Only files matching REPORT_GLOBS are copied (logs and text reports, never
netlists, VCDs, or binaries).
"""
import argparse
import hashlib
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPORT_GLOBS = ["*.log", "*.rpt", "*.txt", "model/*.out", "audit/*.log"]
TOOLS = [["verilator", "--version"], ["yosys", "-V"], ["sby", "--version"],
         ["iverilog", "-V"], ["opensta", "-version"], ["python3", "--version"]]


def sha256(p):
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        return (out.stdout or out.stderr).strip().splitlines()[0] if (out.stdout or out.stderr).strip() else "(no output)"
    except (OSError, subprocess.TimeoutExpired):
        return "(not found)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default="build")
    ap.add_argument("--out", default="evidence/reports")
    a = ap.parse_args()
    build = Path(a.build)
    if not build.is_dir():
        print(f"evidence-snapshot: {build}/ does not exist; run the flow first")
        return 1
    files = sorted({p for g in REPORT_GLOBS for p in build.glob(g) if p.is_file()})
    if not files:
        print(f"evidence-snapshot: no report files under {build}/")
        return 1
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = Path(a.out) / stamp
    out.mkdir(parents=True, exist_ok=False)
    commit = run(["git", "rev-parse", "HEAD"])
    lines = [f"# evidence snapshot {stamp}", f"commit: {commit}", ""]
    lines += [f"tool {c[0]}: {run(c)}" for c in TOOLS] + ["", "sha256  size  file"]
    for p in files:
        dst = out / p.relative_to(build)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, dst)
        lines.append(f"{sha256(p)}  {p.stat().st_size:>9}  {p.relative_to(build)}")
    (out / "MANIFEST.txt").write_text("\n".join(lines) + "\n")
    print(f"evidence-snapshot: {len(files)} report(s) copied to {out}/ (see MANIFEST.txt)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
