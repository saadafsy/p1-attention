#!/usr/bin/env bash
# Block ending a session with a module marked Done that has no passing verify.
[ -f PLAN.md ] || exit 0
grep -oE '\[Done\][[:space:]]+[A-Za-z0-9_]+' PLAN.md 2>/dev/null | awk '{print $2}' | while read -r mod; do
  if ! grep -q "VERIFY OK: $mod" EVIDENCE.md 2>/dev/null; then
    echo "Task '$mod' is marked Done but has no passing verify in EVIDENCE.md." >&2
    exit 2
  fi
done
exit 0
