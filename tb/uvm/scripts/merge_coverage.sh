#!/usr/bin/env bash
# Merge per-seed xsim coverage databases with xcrg into a text report.
# Fails if this xcrg cannot merge (older releases cannot).
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
