#!/usr/bin/env bash
# Compile and run the matmul_tile UVM environment under Vivado xsim (UVM 1.2, -L uvm).
# Usage: run_xsim.sh <test> <seed> <outdir> [extra +plusargs...] [--define MACRO]
#   test    tile_replay_test | tile_random_test
#   seed    integer; also names the coverage database
# Coverage switch names vary by Vivado release; check with `make -C tb/uvm smoke`.
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
