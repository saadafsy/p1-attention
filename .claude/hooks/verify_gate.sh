#!/usr/bin/env bash
# Stop hook: block ending a session with a module marked [Done] in PLAN.md
# that has no "VERIFY OK: <module>" line in EVIDENCE.md.
#
# Rewritten 2026-09-18 (review finding H3). The original had two defects that
# made it a no-op: (1) `exit 2` ran inside a `while read` fed by a pipe, i.e.
# in a subshell, so the outer script always exited 0; (2) the regex captured
# only "rtl" from "[Done] rtl/mac_unit.sv" while EVIDENCE rows read
# "VERIFY OK: mac_unit". The loop now runs in the main shell (process
# substitution) and the module name is the path basename without extension.
set -u
root=${CLAUDE_PROJECT_DIR:-$(pwd)}
cd "$root" || exit 2
[ -f PLAN.md ] || exit 0

status=0
while IFS= read -r mod; do
  [ -n "$mod" ] || continue
  if ! grep -Fxq -- "VERIFY OK: $mod" EVIDENCE.md 2>/dev/null; then
    echo "Task '$mod' is marked [Done] in PLAN.md but has no 'VERIFY OK: $mod' row in EVIDENCE.md." >&2
    status=2
  fi
done < <(sed -nE 's|.*\[Done\][[:space:]]+([A-Za-z0-9_./-]+).*|\1|p' PLAN.md \
         | sed -E 's|^.*/||; s|\.[A-Za-z0-9]+$||')
exit $status
