#!/usr/bin/env bash
# During development this WARNS but does not block (half-written modules warn a lot).
# It hard-blocks (exit 2) ONLY for files listed in .ready_for_lint (one path per line),
# i.e. modules the builder has declared ready. This stops the deadlock where every
# mid-edit save is rejected.
file=$(jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
case "$file" in
  *.sv|*.v)
    command -v verilator >/dev/null 2>&1 || exit 0
    if ! verilator --lint-only -Wall -sv "$file" 2>/tmp/lint.err; then
      if [ -f .ready_for_lint ] && grep -qF "$file" .ready_for_lint; then
        echo "Lint failed on READY file $file:" >&2; cat /tmp/lint.err >&2; exit 2
      else
        echo "Lint warnings on $file (dev mode, not blocking):" >&2; cat /tmp/lint.err >&2; exit 0
      fi
    fi ;;
esac
exit 0
