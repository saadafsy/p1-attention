#!/usr/bin/env bash
# Merge the per-seed xsim coverage databases of a regression and write a
# text report. Vivado's xcrg does this in recent releases; older ones can
# only report a single database. This script probes for the capability and
# FAILS LOUDLY if merging is unavailable, so "merged coverage" is never
# claimed from summed percentages of separate runs.
#
# Usage: merge_coverage.sh <regress_dir>    (contains seed_*/cov/)
set -euo pipefail
dir=${1:?regress_dir}
command -v xcrg >/dev/null 2>&1 || { echo "xcrg not on PATH (source Vivado settings64.sh)"; exit 1; }
dbs=$(ls -d "$dir"/seed_*/cov 2>/dev/null || true)
[ -n "$dbs" ] || { echo "no coverage databases under $dir"; exit 1; }
if ! xcrg -help 2>&1 | grep -qi "merge"; then
  echo "this xcrg has no merge capability; per-seed reports only, no merged number may be claimed"
  exit 1
fi
args=()
for d in $dbs; do args+=("-dir" "$d"); done
xcrg "${args[@]}" -merge_dir "$dir/merged" -report_dir "$dir/merged_report" -report_format text
echo "merged coverage report: $dir/merged_report"
