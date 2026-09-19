#!/usr/bin/env bash
# Compile and run the matmul_tile UVM environment under Vivado xsim.
#
# Usage: run_xsim.sh <test> <seed> <outdir> [extra +plusargs...] [--define MACRO]
#   test    tile_replay_test | tile_random_test
#   seed    integer; also used as the coverage database name
#   outdir  where xvlog/xelab/xsim logs and the coverage db go
#
# Requires `xvlog`, `xelab`, `xsim` on PATH (source <Vivado>/settings64.sh).
# Vivado ships UVM 1.2 as a precompiled library selected with -L uvm.
# Coverage: xelab --cov all and xsim --cov_db_name/--cov_db_dir; the exact
# switch spelling has moved between Vivado releases, so validate with the
# smoke run (`make -C tb/uvm smoke`) before trusting a regression. Merging
# across seeds is done by xcrg in merge_coverage.sh, which probes for the
# capability and fails loudly if this Vivado lacks it.
set -euo pipefail
test_name=${1:?test}; seed=${2:?seed}; outdir=${3:?outdir}; shift 3
root=$(cd "$(dirname "$0")/../../.." && pwd)
defines=()
plusargs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --define) defines+=("-d" "$2"); shift 2 ;;
    *) plusargs+=("$1"); shift ;;
  esac
done
mkdir -p "$outdir"
cd "$outdir"

xvlog -sv -L uvm "${defines[@]}" \
  -i "$root" -i "$root/tb/uvm" \
  "$root/rtl/mac_unit.sv" "$root/rtl/matmul_tile.sv" \
  "$root/tb/uvm/tile_if.sv" "$root/tb/uvm/tile_uvm_pkg.sv" \
  "$root/tb/uvm/tile_assertions.sv" "$root/tb/uvm/tb_top.sv" \
  --log xvlog.log

xelab -L uvm --debug typical --coverage all --relax tb_top -s tile_snap --log xelab.log

# xsim returns nonzero on $fatal; keep the log either way.
set +e
xsim tile_snap -runall -sv_seed "$seed" \
  -testplusarg "UVM_TESTNAME=$test_name" -testplusarg "UVM_VERBOSITY=UVM_LOW" \
  $(for a in "${plusargs[@]}"; do printf -- '-testplusarg %s ' "${a#+}"; done) \
  --cov_db_name "seed_${seed}" --cov_db_dir "$outdir/cov" --log xsim.log
rc=$?
set -e
echo "xsim exit=$rc test=$test_name seed=$seed"
exit $rc
