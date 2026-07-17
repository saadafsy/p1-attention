#!/usr/bin/env python3
"""Threshold gate for coverage, per module. Fails (exit 1) below thresholds.

--module M scopes the check to tb/M/ artifacts ONLY. The old behavior
(pooling every coverage.dat in the repo into one percentage) let a module
below the line threshold hide behind a larger neighbor's points; found in
the 2026-07-16 front-to-back review and fixed here. COVERAGE_STUB=1 keeps
the pre-Phase-3 tolerant-stub escape hatch (tool_smoke).

Line coverage: verilator coverage.dat 'C' points, hit count > 0.
Functional coverage: if tb/M/func_coverage.txt exists (written by the TB's
self-asserting coverage model), its TOTAL line is parsed and gated against
--func. If it does not exist, the gate says so EXPLICITLY and does not
pretend to check it (the older script parsed --func and silently ignored
it); modules whose functional coverage is enforced by in-TB asserts alone
report that fact honestly.
"""
import argparse
import os
import re
import sys
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('--line', type=float, default=90.0)
ap.add_argument('--func', type=float, default=100.0)
ap.add_argument('--module', required=False,
                help='module name; scopes the check to tb/<module>/ only')
a = ap.parse_args()

if os.environ.get('COVERAGE_STUB') == '1':
    print('coverage: STUB pass (COVERAGE_STUB=1, pre-Phase-3)')
    sys.exit(0)

if not a.module:
    print('coverage: --module is required (per-module gate; the old pooled '
          'mode was removed, 2026-07-16 review finding)')
    sys.exit(1)

tbdir = Path('tb') / a.module
dat = tbdir / 'coverage.dat'
if not dat.is_file():
    print(f'coverage: {dat} not found. Run verilator with --coverage-line, '
          'or set COVERAGE_STUB=1 for early phases.')
    sys.exit(1)

# Line coverage: verilator coverage.dat 'C' points; last field is hit count.
covered = total = 0
for ln in dat.open():
    if ln.startswith('C '):
        total += 1
        try:
            if int(ln.split()[-1]) > 0:
                covered += 1
        except ValueError:
            pass
if total == 0:
    print(f'coverage: {dat} had no C points; set COVERAGE_STUB=1 if pre-Phase-3.')
    sys.exit(1)
pct = 100.0 * covered / total
line_ok = pct >= a.line
print(f'coverage[{a.module}]: line {covered}/{total} = {pct:.1f}% '
      f'(threshold {a.line}%) {"PASS" if line_ok else "FAIL"}')

# Functional coverage: parse the TB-written report when it exists.
func_ok = True
freport = tbdir / 'func_coverage.txt'
if freport.is_file():
    m = re.search(r'TOTAL:\s*(\d+)/(\d+)\s+reachable bins hit\s+\(([\d.]+)%\)',
                  freport.read_text())
    if not m:
        print(f'coverage[{a.module}]: func {freport} exists but has no '
              'parseable TOTAL line FAIL')
        func_ok = False
    else:
        fhit, ftot, fpct = int(m.group(1)), int(m.group(2)), float(m.group(3))
        func_ok = fpct >= a.func
        print(f'coverage[{a.module}]: func {fhit}/{ftot} reachable bins = '
              f'{fpct:.1f}% (threshold {a.func}%) '
              f'{"PASS" if func_ok else "FAIL"}')
else:
    print(f'coverage[{a.module}]: func no func_coverage.txt; functional '
          'coverage for this module is enforced by in-TB self-asserts only '
          '(NOT checked here)')

sys.exit(0 if (line_ok and func_ok) else 1)
