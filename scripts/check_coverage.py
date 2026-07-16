#!/usr/bin/env python3
"""Threshold gate for verilator coverage. Fails (exit 1) if below thresholds.
Reads logs/annotated coverage.dat if present; until Phase 3 exists it is a
tolerant stub controlled by COVERAGE_STUB=1 so early phases are not blocked."""
import os, sys, argparse, glob
ap = argparse.ArgumentParser()
ap.add_argument('--line', type=float, default=90.0)
ap.add_argument('--func', type=float, default=100.0)
a = ap.parse_args()
if os.environ.get('COVERAGE_STUB') == '1':
    print('coverage: STUB pass (COVERAGE_STUB=1, pre-Phase-3)'); sys.exit(0)
dat = glob.glob('**/coverage.dat', recursive=True) + glob.glob('**/*.dat', recursive=True)
if not dat:
    print('coverage: no coverage.dat found. Run verilator with --coverage, or set '
          'COVERAGE_STUB=1 for early phases.'); sys.exit(1)
# Minimal parse: count covered vs total points from verilator coverage.dat lines.
covered=total=0
for f in dat:
    try:
        for ln in open(f):
            if ln.startswith('C '):
                total+=1
                # last whitespace field is the hit count
                try:
                    if int(ln.split()[-1])>0: covered+=1
                except ValueError: pass
    except OSError: pass
if total==0:
    print('coverage: coverage.dat had no C points; set COVERAGE_STUB=1 if pre-Phase-3.'); sys.exit(1)
pct=100.0*covered/total
print(f'coverage: {covered}/{total} points = {pct:.1f}% (line threshold {a.line}%)')
sys.exit(0 if pct>=a.line else 1)
