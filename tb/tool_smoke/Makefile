# cocotb testbench for tool_smoke (Phase -1 pipeline smoke test).
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)
VERILOG_SOURCES = $(PWD)/../../rtl/tool_smoke.sv

COCOTB_TOPLEVEL = tool_smoke
COCOTB_TEST_MODULES = test_tool_smoke

# Top-level Makefile passes SEED=; map it onto cocotb 2.x's variable.
SEED ?= 1
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
