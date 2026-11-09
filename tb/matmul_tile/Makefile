# cocotb testbench for matmul_tile with verilator line coverage
# (coverage.dat, read by scripts/check_coverage.py).
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)
VERILOG_SOURCES = $(PWD)/../../rtl/mac_unit.sv $(PWD)/../../rtl/matmul_tile.sv

COCOTB_TOPLEVEL = matmul_tile
COCOTB_TEST_MODULES = test_matmul_tile

EXTRA_ARGS += --coverage-line

SEED ?= 1
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
