#!/usr/bin/env bash
# Claude Code statusline: P1 build progress computed from PLAN.md.
#
# Rewritten 2026-09-18 (review finding L5): the old version summed EVIDENCE
# row counts against a hard-coded TOTAL=17 that assumed 8 auditor rows; the
# ledger grew to 12 unique audit ids, the sum (21) was clamped to 17 and the
# bar read 100% while PLAN.md had zero [Done] items. Progress is now the
# fraction of PLAN.md tasks in [Ready] or [Done] (half credit for Building),
# so it can only move when PLAN.md moves.
cd "$(dirname "$0")/.." || exit 0
[ -f PLAN.md ] || { echo "P1 [..........] no PLAN.md"; exit 0; }
total=$(grep -cE '^- \[(Todo|Building|Ready|Done|Blocked: needs bench)\]' PLAN.md)
ready=$(grep -cE '^- \[(Ready|Done)\]' PLAN.md)
building=$(grep -cE '^- \[Building\]' PLAN.md)
done_n=$(grep -cE '^- \[Done\]' PLAN.md)
[ "$total" -gt 0 ] || total=1
units=$((ready * 2 + building))          # in half-task units
pct=$((units * 100 / (total * 2)))
filled=$((units * 10 / (total * 2)))
bar=""
for i in $(seq 1 10); do
  if [ "$i" -le "$filled" ]; then bar="${bar}#"; else bar="${bar}."; fi
done
eta=""
[ -f .claude/eta.txt ] && eta=" | $(head -1 .claude/eta.txt)"
echo "P1 [${bar}] ${pct}% (${ready}/${total} ready, ${done_n} done)${eta}"
