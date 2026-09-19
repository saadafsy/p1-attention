# cocotb testbench for tile_runner (Phase 6 first-bring-up helper, outside
# the core verify flow). Fixed-function block, one directed test is enough
# (guide 6.3.5 documents the exact stimulus and expected accumulators). No
# verilator --coverage here (outside the core verify flow; check_coverage.py
# only reads tb/<module>/ for the module it is asked about).
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)
VERILOG_SOURCES = $(PWD)/../../rtl/mac_unit.sv \
                   $(PWD)/../../rtl/matmul_tile.sv \
                   $(PWD)/../../fpga/tile_runner.sv

COCOTB_TOPLEVEL = tile_runner
COCOTB_TEST_MODULES = test_tile_runner

SEED ?= 1
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
