#!/usr/bin/env bash
# Copy into the p1-attention clone's rebuild/ directory and run from that clone.
# This invokes the existing cocotb testbench without editing it.
set -euo pipefail

if (( $# != 1 )); then
    echo "Usage: bash rebuild/verify.sh <mac_unit|matmul_tile|online_softmax>" >&2
    exit 2
fi

module=$1
pipe_rom=${PIPE_ROM:-0}
case "$module" in
    mac_unit|matmul_tile|online_softmax) ;;
    *) echo "Unsupported module: $module" >&2; exit 2 ;;
esac
if [[ $pipe_rom != 0 && $pipe_rom != 1 ]]; then
    echo "PIPE_ROM must be 0 or 1" >&2
    exit 2
fi
if [[ $module != online_softmax && $pipe_rom != 0 ]]; then
    echo "PIPE_ROM=1 is only supported for online_softmax" >&2
    exit 2
fi

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
if [[ ! -f $root/tb/$module/Makefile || ! -f $root/rtl_rebuild/$module.sv ]]; then
    echo "Run in the p1-attention clone with tb/$module and rtl_rebuild/$module.sv" >&2
    exit 2
fi

sources=("$root/rtl_rebuild/$module.sv")
if [[ $module == matmul_tile ]]; then
    [[ -f $root/rtl_rebuild/mac_unit.sv ]] || { echo "Missing rtl_rebuild/mac_unit.sv" >&2; exit 2; }
    sources=("$root/rtl_rebuild/mac_unit.sv" "${sources[@]}")
fi
if [[ $module == online_softmax ]]; then
    rom="$root/rtl_rebuild/exp_lut_2p.sv"
    if [[ ! -f $rom ]]; then
        if [[ $pipe_rom == 1 ]]; then
            echo "PIPE_ROM=1 requires rtl_rebuild/exp_lut_2p.sv" >&2
            exit 2
        fi
        rom="$root/rtl/exp_lut_2p.sv"
    fi
    [[ -f $rom ]] || { echo "Missing exp_lut_2p.sv" >&2; exit 2; }
    sources=("$rom" "${sources[@]}")
fi

build=sim_build_rebuild
if [[ $pipe_rom == 1 ]]; then
    build=sim_build_rebuild_pipe_rom1
    sources=("$root/tb/online_softmax/coverage_pipe_rom1.vlt" "${sources[@]}")
fi

printf -v source_list '%s ' "${sources[@]}"
source_list=${source_list% }
cmd=(make -C "tb/$module" SIM=verilator "PIPE_ROM=$pipe_rom" "SIM_BUILD=$build" "VERILOG_SOURCES=$source_list" MODULE=)
how="bash rebuild/verify.sh $module"
if [[ $pipe_rom == 1 ]]; then
    how="PIPE_ROM=1 $how"
fi
echo "EVIDENCE HOW: $how"
printf 'Running:'
printf ' %q' "${cmd[@]}"
printf '\n'
if (cd "$root" && "${cmd[@]}"); then
    echo "PASS: $how"
else
    echo "FAIL: $how" >&2
    exit 1
fi
