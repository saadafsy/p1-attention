# cocotb testbench for attn_uart_top (Phase 6 bring-up kit, outside the core
# verify flow: this directory is never referenced by the root Makefile or
# scripts/check_coverage.py). No verilator --coverage here on purpose (see
# test_fpga_uart.py docstring): a coverage.dat written here would be picked
# up by scripts/check_coverage.py's recursive **/coverage.dat glob and skew
# the core gate with an unrelated line count.
#
# CLK_HZ/BAUD are overridden to the SMALLEST ratio the elaboration-time check
# in fpga/uart_rx.sv / fpga/uart_tx.sv allows (CLK_HZ/BAUD >= 16, guide
# 6.3.3): 1_600_000 / 100_000 = 16 exactly. At the board defaults
# (100_000_000 / 115_200 = 868 clocks/bit) one UART byte alone is 8680 clock
# edges; a full n_len=64 run (~6593 core clocks) plus dozens of protocol
# bytes would make this testbench too slow to run routinely. ClksPerBit=16
# keeps the SAME RTL (majority-of-3 vote, same margins) exercised at a
# simulation-tractable byte rate; it is a testbench-only parameter override,
# never touches the board defaults.
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)
VERILOG_SOURCES = $(PWD)/../../rtl/mac_unit.sv \
                   $(PWD)/../../rtl/matmul_tile.sv \
                   $(PWD)/../../rtl/online_softmax.sv \
                   $(PWD)/../../rtl/attention_top.sv \
                   $(PWD)/../../fpga/sync2ff.sv \
                   $(PWD)/../../fpga/heartbeat.sv \
                   $(PWD)/../../fpga/uart_rx.sv \
                   $(PWD)/../../fpga/uart_tx.sv \
                   $(PWD)/../../fpga/attn_uart_top.sv

COCOTB_TOPLEVEL = attn_uart_top
COCOTB_TEST_MODULES = test_fpga_uart

# `include "rtl/exp_lut.svh" inside online_softmax.sv is repo-root-relative
# (docs/uarch.md 8.2); same incdir fix as tb/attention_top/Makefile.
EXTRA_ARGS += +incdir+$(PWD)/../..
EXTRA_ARGS += -GCLK_HZ=1600000 -GBAUD=100000

SEED ?= 1
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
