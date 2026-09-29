#!/usr/bin/env bash
# Compile and run the matmul_tile UVM environment under Verilator with the
# upstream Accellera UVM 1800.2-2017-1.0 library (the bootcamp's M5 route,
# Day 45). Same interface as run_xsim.sh so tb/uvm/Makefile can switch with
# SIM=verilator.
#
# Usage: run_verilator.sh <test> <seed> <outdir> [+plusargs...] [--define MACRO] [--no-sva]
#   --no-sva  leave tile_assertions.sv out of the compile, so a bug can only be
#             caught by the scoreboard (used by the second bug-proof leg)
#
# Needs: verilator on PATH, UVM_HOME (default $HOME/tools/uvm/1800.2-2017-1.0/src).
# Builds are cached per (defines, sva) under build/uvm_verilator/ and rebuilt
# when any source is newer. No coverage database: Verilator's covergroup
# support is partial and there is no xcrg-style merge, so merged coverage is
# NOT produced by this flow.
set -euo pipefail
test_name=${1:?test}; seed=${2:?seed}; outdir=${3:?outdir}; shift 3
root=$(cd "$(dirname "$0")/../../.." && pwd)
UVM_HOME=${UVM_HOME:-$HOME/tools/uvm/1800.2-2017-1.0/src}
[ -f "$UVM_HOME/uvm_pkg.sv" ] || { echo "run_verilator.sh: UVM_HOME=$UVM_HOME has no uvm_pkg.sv" >&2; exit 2; }
defines=(); plusargs=(); sva=1; key=base
while [ $# -gt 0 ]; do
  case "$1" in
    --define) defines+=("+define+$2"); key="$key-$2"; shift 2 ;;
    --no-sva) sva=0; key="$key-nosva"; shift ;;
    *) plusargs+=("$1"); shift ;;
  esac
done
obj="$root/build/uvm_verilator/obj_$key"
srcs=("$root/rtl/mac_unit.sv" "$root/rtl/matmul_tile.sv"
      "$root/tb/uvm/tile_if.sv" "$root/tb/uvm/tile_uvm_pkg.sv")
[ "$sva" = 1 ] && srcs+=("$root/tb/uvm/tile_assertions.sv")
srcs+=("$root/tb/uvm/tb_top.sv")
mkdir -p "$outdir" "$root/build/uvm_verilator"
stale=0
if [ ! -x "$obj/Vtb_top" ]; then stale=1
elif [ -n "$(find "$root/rtl" "$root/tb/uvm" -name '*.sv' -newer "$obj/Vtb_top" 2>/dev/null | head -1)" ]; then stale=1; fi
if [ "$stale" = 1 ]; then
  ( cd "$root" && verilator -Wno-fatal --binary -j "$(nproc)" --top-module tb_top --Mdir "$obj" \
      "+incdir+$UVM_HOME" +define+UVM_NO_DPI "${defines[@]}" "+incdir+$root/tb/uvm" "+incdir+$root" \
      "$UVM_HOME/uvm_pkg.sv" "${srcs[@]}" ) > "$outdir/compile.log" 2>&1 \
    || { echo "run_verilator.sh: compile failed, see $outdir/compile.log" >&2; exit 2; }
fi
cd "$outdir"
set +e
"$obj/Vtb_top" "+UVM_TESTNAME=$test_name" "+verilator+seed+$seed" +UVM_VERBOSITY=UVM_LOW "${plusargs[@]}" > sim.log 2>&1
rc=$?
set -e
echo "verilator exit=$rc test=$test_name seed=$seed"
exit $rc
