#!/usr/bin/env bash
# Claude Code statusline: P1 build progress computed from EVIDENCE.md.
# Milestone units (17 total):
#   6 x "VERIFY OK" rows   (tool_smoke, attn_model, mac_unit, matmul_tile,
#                           online_softmax, attention_top)
#   8 x auditor countersign rows (4 RTL modules x 2 auditors)
#   3 x phase rows (ids: phase3-closure, phase4-sta, phase5-docs)
cd "$(dirname "$0")/.." || exit 0
TOTAL=17
# Unique row ids only: repeat runs re-append rows (e.g. model-check), and a
# progress bar must not inflate from reruns.
v=$(grep "VERIFY OK" EVIDENCE.md 2>/dev/null | sort -u | wc -l)
a=$(grep "^| audit-" EVIDENCE.md 2>/dev/null | cut -d'|' -f2 | sort -u | wc -l)
p=$(grep -E "^\| (phase3-closure|phase4-sta|phase5-docs) " EVIDENCE.md 2>/dev/null | cut -d'|' -f2 | sort -u | wc -l)
done_units=$((v + a + p))
[ "$done_units" -gt "$TOTAL" ] && done_units=$TOTAL
pct=$((done_units * 100 / TOTAL))
filled=$((done_units * 10 / TOTAL))
bar=""
for i in $(seq 1 10); do
  if [ "$i" -le "$filled" ]; then bar="${bar}#"; else bar="${bar}."; fi
done
eta=""
[ -f .claude/eta.txt ] && eta=" | $(head -1 .claude/eta.txt)"
echo "P1 [${bar}] ${pct}% (${done_units}/${TOTAL})${eta}"
