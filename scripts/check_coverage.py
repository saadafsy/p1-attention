#!/usr/bin/env python3
"""Threshold gate for coverage, per module. Fails (exit 1) below thresholds.

--module M scopes the check to tb/M/ artifacts ONLY (the old pooled
**/coverage.dat mode let a module hide behind a neighbor; removed 2026-07-16).
--dat selects the artifact inside tb/M/ (default coverage.dat; the PIPE_ROM=1
run of online_softmax writes coverage_pipe_rom1.dat and is gated separately,
2026-09-18 review finding M6). COVERAGE_STUB=1 keeps the pre-Phase-3
tolerant-stub escape hatch (tool_smoke).

Line coverage (2026-09-18 review finding F004): ONLY verilator records whose
metadata says t=line are counted. The previous script counted every 'C'
record, pooling t=branch points into the "line" percentage; on attention_top
that turned a true 46/53 = 86.8% (below the 90% gate) into a reported
144/151 = 95.4% PASS. Branch coverage is now reported separately, not gated.

Documented-unreachable lines are waived through tb/M/coverage_waivers.txt,
one per line: `<source basename>:<line> <reason>`. A waiver is applied only to
a point that exists in the artifact and is unhit; a waiver that matches
nothing (stale) or matches a HIT point is an error, so waivers cannot rot.
Raw, waived, and effective figures are all printed. This mirrors the
functional model's declared UNREACHABLE bins (test_softmax_coverage.py).

Functional coverage: if tb/M/func_coverage.txt exists (written by the TB's
self-asserting coverage model), its TOTAL line is parsed and gated against
--func. If it does not exist, the gate says so EXPLICITLY.
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
    """Yield (type, source_basename, line, hits) per verilator 'C' record.
    Keys are \\x01key\\x02value pairs inside the quoted string."""
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
line_ok = eff_pct >= a.line and not waiver_errors

print(f'coverage[{a.module}] ({a.dat}): line raw {raw_hit}/{raw_total} = {raw_pct:.1f}%; '
      f'waived {len(waived)} documented-unreachable; effective {eff_hit}/{eff_total} = '
      f'{eff_pct:.1f}% (threshold {a.line}%) {"PASS" if line_ok else "FAIL"}')
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
