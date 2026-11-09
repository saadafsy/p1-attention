#!/usr/bin/env bash
# Open-source place-and-route of the Basys 3 board top (fpga/nexys_a7_top.sv,
# MMCM at 100 MHz) with the openXC7 flow:
#   yosys synth_xilinx -> nextpnr-himbaechel (xilinx uarch, Project X-Ray chipdb)
#   -> fasm2frames -> xc7frames2bit
# Usage (from anywhere):  bash fpga/openxc7/build.sh
# Env overrides: OPENXC7 (toolchain prefix, default ~/tools/openxc7),
#   YOSYS (default: oss-cad-suite yosys), SEED (default 1), OUT (default build/openxc7).
# Outputs in $OUT: nexys_a7_top.json/.fasm/.frames/.bit, synth.log, pnr.log,
#   report.json (nextpnr timing + utilisation), summary.txt.
# Produces a bitstream only; nothing here touches a board.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OPENXC7="${OPENXC7:-$HOME/tools/openxc7}"
YOSYS="${YOSYS:-$HOME/oss-cad-suite/bin/yosys}"
SEED="${SEED:-1}"
OUT="${OUT:-$ROOT/build/openxc7}"
PART=xc7a35tcpg236-1
DIE=xc7a50t            # xc7a35t is the xc7a50t die in Project X-Ray
FAMILY=artix7
TOP=nexys_a7_top
# The board XDC is used unchanged: nextpnr's XDC subset reads PACKAGE_PIN,
# IOSTANDARD and create_clock, and warns on (ignores) set_false_path and the
# [current_design] CFGBVS/CONFIG_VOLTAGE properties.
XDC="$ROOT/fpga/basys3.xdc"

# shellcheck disable=SC1091
source "$OPENXC7/export.sh"
DB="$PRJXRAY_DB_DIR"
GEN="$OPENXC7/share/nextpnr/himbaechel/uarch/xilinx/gen/xilinx_gen.py"
CHIPDB_DIR="$OPENXC7/share/nextpnr/himbaechel/xilinx"
CHIPDB="$CHIPDB_DIR/chipdb-$DIE.bin"
mkdir -p "$OUT" "$CHIPDB_DIR"

# 1. Chip database (once; ~minutes). Generated from the pinned prjxray-db.
if [[ ! -s "$CHIPDB" ]]; then
  echo "== generating $CHIPDB"
  python3 "$GEN" --xray "$DB/$FAMILY" --device "$DIE" --bba "$OUT/chipdb-$DIE.bba"
  bbasm --l "$OUT/chipdb-$DIE.bba" "$CHIPDB.tmp"
  mv "$CHIPDB.tmp" "$CHIPDB"
  rm -f "$OUT/chipdb-$DIE.bba"
fi

# 2. Synthesis. XILINX_FPGA is NOT defined (that path needs Vivado's XPM);
#    the generic exp_lut_1p ROM and sync_ram templates are left to yosys inference.
SRCS=(rtl/mac_unit.sv rtl/matmul_tile.sv rtl/exp_lut_1p.sv rtl/sync_ram.sv
      rtl/online_softmax.sv rtl/attention_top.sv
      fpga/sync2ff.sv fpga/heartbeat.sv fpga/uart_rx.sv fpga/uart_tx.sv
      fpga/attn_uart_top.sv fpga/nexys_a7_top.sv)
cd "$ROOT"
echo "== yosys ($("$YOSYS" -V))"
"$YOSYS" -q -l "$OUT/synth.log" -p "
  read_verilog -sv -I$ROOT ${SRCS[*]};
  synth_xilinx -flatten -abc9 -arch xc7 -top $TOP;
  tee -o $OUT/synth_stat.txt stat;
  write_json $OUT/$TOP.json"

# 3. Place and route (timing-driven, router2), FASM out.
echo "== nextpnr-himbaechel (xilinx)"
nextpnr-himbaechel --chipdb "$CHIPDB" --device "$PART" --json "$OUT/$TOP.json" \
  -o xdc="$XDC" -o fasm="$OUT/$TOP.fasm" --router router2 --seed "$SEED" --threads "${THREADS:-6}" \
  --report "$OUT/report.json" --log "$OUT/pnr.log"

# 4. Bitstream.
echo "== fasm2frames + xc7frames2bit"
fasm2frames --part "$PART" --db-root "$DB/$FAMILY" "$OUT/$TOP.fasm" "$OUT/$TOP.frames"
xc7frames2bit --part_file "$DB/$FAMILY/$PART/part.yaml" --part_name "$PART" \
  --frm_file "$OUT/$TOP.frames" --output_file "$OUT/$TOP.bit"

# 5. Summary.
{
  echo "openXC7 build of $TOP for $PART (Basys 3), seed $SEED"
  echo "yosys: $("$YOSYS" -V)"
  echo "nextpnr: $(nextpnr-himbaechel --version 2>&1 | head -1)"
  echo "--- post-route timing (nextpnr)"
  grep -E "Max frequency for clock|Max delay" "$OUT/pnr.log" | tail -n 8
  echo "--- utilisation (nextpnr)"
  sed -n '/Device utilisation:/,/^Info: *$/p' "$OUT/pnr.log" | grep -E ' [1-9][0-9]*/ *[0-9]+' || true
  echo "--- bitstream"
  ls -l "$OUT/$TOP.bit"
  if grep -q "FAIL at" "$OUT/pnr.log"; then
    echo "TIMING: FAILED at the constrained frequency (bitstream still written; Vivado's build.tcl would refuse it)"
  fi
  echo "NOT run on a board: no hardware evidence. Bitstream is untested."
} | tee "$OUT/summary.txt"
