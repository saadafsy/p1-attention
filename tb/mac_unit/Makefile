# cocotb testbench for mac_unit with verilator line coverage
# (coverage.dat, read by scripts/check_coverage.py).
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)
VERILOG_SOURCES = $(PWD)/../../rtl/mac_unit.sv

COCOTB_TOPLEVEL = mac_unit
COCOTB_TEST_MODULES = test_mac_unit

EXTRA_ARGS += --coverage-line

SEED ?= 1
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
