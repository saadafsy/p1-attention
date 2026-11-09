# cocotb testbench for fpga/tile_runner.sv (outside the core verify flow, no coverage).
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
