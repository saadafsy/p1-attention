#!/usr/bin/env bash
# Artix-7 resource estimate for the FPGA top (fpga/attn_uart_top.sv) with
# yosys synth_xilinx, no Vivado needed. Confirms the memories and exp ROMs
# map to block RAM and the multipliers to DSP48E1. It is a synthesis-only
# count: no placement, no timing (Fmax on the FPGA needs Vivado, see
# fpga/scripts/build.tcl). Output: build/fpga_resources.txt.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
yosys -p "read_verilog -sv -defer rtl/mac_unit.sv rtl/matmul_tile.sv rtl/exp_lut_1p.sv rtl/sync_ram.sv \
  rtl/online_softmax.sv rtl/attention_top.sv fpga/sync2ff.sv fpga/heartbeat.sv fpga/uart_rx.sv \
  fpga/uart_tx.sv fpga/attn_uart_top.sv; hierarchy -top attn_uart_top; \
  synth_xilinx -family xc7 -top attn_uart_top; tee -o build/fpga_resources.txt stat" > build/fpga_resources.log 2>&1
grep -E 'RAMB|DSP48|LUT[1-6]|FD[RSCP]E|CARRY4|Number of cells' build/fpga_resources.txt
