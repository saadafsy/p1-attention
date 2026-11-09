# cocotb testbench for fpga/attn_uart_top.sv (outside the core verify flow;
# protocol coverage is checked inside test_fpga_uart.py).
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)
VERILOG_SOURCES = $(PWD)/../../rtl/mac_unit.sv \
                   $(PWD)/../../rtl/matmul_tile.sv \
                   $(PWD)/../../rtl/exp_lut_1p.sv \
                   $(PWD)/../../rtl/sync_ram.sv \
                   $(PWD)/../../rtl/online_softmax.sv \
                   $(PWD)/../../rtl/attention_top.sv \
                   $(PWD)/../../fpga/sync2ff.sv \
                   $(PWD)/../../fpga/heartbeat.sv \
                   $(PWD)/../../fpga/uart_rx.sv \
                   $(PWD)/../../fpga/uart_tx.sv \
                   $(PWD)/../../fpga/attn_uart_top.sv

COCOTB_TOPLEVEL = attn_uart_top
COCOTB_TEST_MODULES = test_fpga_uart

# Repo root, for `include "rtl/exp_lut.svh".
EXTRA_ARGS += +incdir+$(PWD)/../..
# 16 clocks/bit, the minimum uart_rx/tx allow; board rate (868) is too slow to simulate.
EXTRA_ARGS += -GCLK_HZ=1600000 -GBAUD=100000

SEED ?= 1
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
