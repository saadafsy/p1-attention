#!/usr/bin/env python3
"""Per-module coverage gate over tb/<module>/ artifacts; exit 1 below thresholds.

Gates only t=line Verilator points (branch is reported). Waivers (coverage_waivers.txt,
`<file>:<line> <reason>`) and file exclusions (coverage_exclude*.txt, `<file> <reason>`)
must match an instrumented point, so stale entries fail. Functional coverage is gated
from func_coverage.txt when present. COVERAGE_STUB=1 passes (tool_smoke only).
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
ap.add_argument('--dat', default='coverage.dat',
                help='coverage artifact inside tb/<module>/ (default coverage.dat)')
a = ap.parse_args()

if os.environ.get('COVERAGE_STUB') == '1':
    print('coverage: STUB pass (COVERAGE_STUB=1, pre-Phase-3)')
    sys.exit(0)

if not a.module:
    print('coverage: --module is required (per-module gate; the old pooled '
          'mode was removed, 2026-07-16 review finding)')
    sys.exit(1)

tbdir = Path('tb') / a.module
dat = tbdir / a.dat
if not dat.is_file():
    print(f'coverage: {dat} not found. Run the simulation (make sim) with '
          'verilator --coverage-line first; coverage artifacts are generated, '
          'not tracked. Set COVERAGE_STUB=1 only for early phases.')
    sys.exit(1)


def parse_records(path):
    """Yield (type, source_basename, line, hits) per verilator 'C' record (\\x01key\\x02value pairs)."""
    for ln in path.open(encoding='utf-8', errors='replace'):
        if not ln.startswith('C '):
            continue
        try:
            hits = int(ln.rsplit(None, 1)[-1])
        except ValueError:
            continue
        kv = dict(re.findall(r'\x01([^\x01\x02]+)\x02([^\x01\x02]*)', ln))
        src = os.path.basename(kv.get('f', '')) or '?'
        try:
            line = int(kv.get('l', '0'))
        except ValueError:
            line = 0
        yield kv.get('t', '?'), src, line, hits


line_pts = []   # (src, line, hits)
branch_total = branch_hit = 0
for t, src, line, hits in parse_records(dat):
    if t == 'line':
        line_pts.append((src, line, hits))
    elif t == 'branch':
        branch_total += 1
        branch_hit += hits > 0

# ---- whole-file exclusions ---------------------------------------------------
excl = {}
excl_errors = []
efile = tbdir / ('coverage_exclude_pipe_rom1.txt' if a.dat == 'coverage_pipe_rom1.dat'
                 else 'coverage_exclude.txt')
if efile.is_file():
    for raw in efile.read_text().splitlines():
        s_ = raw.strip()
        if not s_ or s_.startswith('#'):
            continue
        m = re.match(r'^(\S+)\s+(.+)$', s_)
        if not m:
            excl_errors.append(f'unparseable exclusion line: {raw!r}')
            continue
        excl[m.group(1)] = m.group(2)
excluded_n = {}
for name in excl:
    n = sum(1 for src, _, _ in line_pts if src == name)
    if n == 0:
        excl_errors.append(f'stale exclusion {name} matches no instrumented line')
    excluded_n[name] = n
line_pts = [pt for pt in line_pts if pt[0] not in excl]

if not line_pts:
    print(f'coverage[{a.module}]: {dat} had no t=line points; set COVERAGE_STUB=1 if pre-Phase-3.')
    sys.exit(1)

# ---- waivers ---------------------------------------------------------------
waivers = {}
wfile = tbdir / 'coverage_waivers.txt'
waiver_errors = []
if wfile.is_file():
    for raw in wfile.read_text().splitlines():
        s = raw.strip()
        if not s or s.startswith('#'):
            continue
        m = re.match(r'^(\S+?):(\d+)\s+(.+)$', s)
        if not m:
            waiver_errors.append(f'unparseable waiver line: {raw!r}')
            continue
        waivers[(m.group(1), int(m.group(2)))] = m.group(3)

unhit = {(s, l) for s, l, h in line_pts if h == 0}
present = {(s, l) for s, l, h in line_pts}
waived = set()
for key, reason in waivers.items():
    if key[0] in excl:
        continue  # whole file excluded for this artifact; its waiver applies to the other run
    if key not in present:
        waiver_errors.append(f'stale waiver {key[0]}:{key[1]} matches no instrumented line')
    elif key not in unhit:
        waiver_errors.append(f'waiver {key[0]}:{key[1]} names a line that IS hit; remove it')
    else:
        waived.add(key)

raw_total = len(line_pts)
raw_hit = sum(1 for _, _, h in line_pts if h > 0)
eff_total = raw_total - len(waived)
eff_hit = raw_hit
raw_pct = 100.0 * raw_hit / raw_total
eff_pct = 100.0 * eff_hit / eff_total if eff_total else 100.0
line_ok = eff_pct >= a.line and not waiver_errors and not excl_errors

print(f'coverage[{a.module}] ({a.dat}): line raw {raw_hit}/{raw_total} = {raw_pct:.1f}%; '
      f'waived {len(waived)} documented-unreachable; effective {eff_hit}/{eff_total} = '
      f'{eff_pct:.1f}% (threshold {a.line}%) {"PASS" if line_ok else "FAIL"}')
for name, reason in sorted(excl.items()):
    print(f'    EXCLUDED  {name} ({excluded_n[name]} line points not counted)  {reason}')
for e in excl_errors:
    print(f'    EXCLUSION ERROR  {e}')
if branch_total:
    print(f'coverage[{a.module}]: branch {branch_hit}/{branch_total} = '
          f'{100.0 * branch_hit / branch_total:.1f}% (reported, not gated)')
for s, l in sorted(waived):
    print(f'    WAIVED  {s}:{l}  {waivers[(s, l)]}')
for s, l in sorted(unhit - waived):
    print(f'    UNHIT   {s}:{l}')
for e in waiver_errors:
    print(f'    WAIVER ERROR  {e}')

# ---- functional coverage ----------------------------------------------------
func_ok = True
freport = tbdir / ('func_coverage_pipe_rom1.txt' if a.dat == 'coverage_pipe_rom1.dat'
                   else 'func_coverage.txt')
if freport.is_file():
    m = re.search(r'TOTAL:\s*(\d+)/(\d+)\s+(?:reachable\s+)?bins hit\s+\(([\d.]+)%\)',
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
    print(f'coverage[{a.module}]: func no {freport.name}; functional '
          'coverage for this module is enforced by in-TB self-asserts only '
          '(NOT checked here)')

sys.exit(0 if (line_ok and func_ok) else 1)
