#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): lint an edited .sv/.v file with verilator.
# WARNS during development; hard-blocks (exit 2) only for files listed in
# .ready_for_lint (repo-relative paths, one per line).
#
# Rewritten 2026-09-18 (review finding H4). The original (1) compared the
# ABSOLUTE tool_input.file_path against the RELATIVE entries of
# .ready_for_lint, so the hard-block never fired; (2) linted the single file
# alone, so online_softmax.sv (`include "rtl/exp_lut.svh"), matmul_tile.sv
# and attention_top.sv (submodules) always errored regardless of content.
# Now: path is made repo-relative, the whole rtl/ set (plus the edited
# file's own directory, e.g. fpga/) is elaborated with the repo root as the
# include dir and the edited module as top.
set -u
root=${CLAUDE_PROJECT_DIR:-$(pwd)}
cd "$root" || exit 0

abs=$(jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
case "$abs" in
  *.sv|*.v) ;;
  *) exit 0 ;;
esac
command -v verilator >/dev/null 2>&1 || exit 0

rel=$(realpath --relative-to="$root" "$abs" 2>/dev/null || printf '%s' "$abs")
rel=${rel#./}
mod=$(basename "$rel"); mod=${mod%.*}
dir=$(dirname "$rel")

srcs=(rtl/*.sv)
if [ "$dir" != "rtl" ]; then srcs+=("$dir"/*.sv); fi

err=$(mktemp); trap 'rm -f "$err"' EXIT
if ! verilator --lint-only -Wall -sv +incdir+. --top-module "$mod" "${srcs[@]}" 2>"$err"; then
  if [ -f .ready_for_lint ] && grep -Fxq -- "$rel" .ready_for_lint; then
    echo "Lint failed on READY file $rel:" >&2; sed 's/^/  /' "$err" >&2; exit 2
  fi
  echo "Lint warnings on $rel (dev mode, not blocking):" >&2; sed 's/^/  /' "$err" >&2
fi
exit 0
