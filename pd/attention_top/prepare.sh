#!/usr/bin/env bash
# Runs in the ORFS container before the flow: writes the patched macro LEFs
# (patch_sram_lef.py) to /work/build/lef, where config.mk reads them.
set -euo pipefail
SRC=/OpenROAD-flow-scripts/flow/platforms/sky130ram
mkdir -p /work/build/lef
for m in 64x256_8 128x256_8; do
  python3 /work/pd/attention_top/patch_sram_lef.py \
    "$SRC/sky130_sram_1rw1r_$m/sky130_sram_1rw1r_$m.lef" \
    "/work/build/lef/sky130_sram_1rw1r_$m.lef"
done
