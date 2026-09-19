# Language-agnostic replay testbench for mac_unit (target-scores change 9,
# added 2026-09-19). LANG=vhdl simulates rtl_vhdl/mac_unit.vhd under GHDL;
# LANG=verilog simulates rtl/mac_unit.sv under verilator; both replay the
# same vector file and write a trace. The repo-root target
# `make vhdl-crosscheck` runs both and byte-compares the traces.
# Never run yet (no simulator where this was written).
LANG ?= vhdl
SEED ?= 5
PWD := $(shell pwd)
VECTOR_FILE ?= $(PWD)/vectors/mac_seed_$(SEED).txt
export VECTOR_FILE
export TRACE_FILE ?= $(PWD)/trace_$(LANG).txt

ifeq ($(LANG),vhdl)
SIM ?= ghdl
TOPLEVEL_LANG = vhdl
VHDL_SOURCES = $(PWD)/../../rtl_vhdl/mac_unit.vhd
SIM_BUILD ?= sim_build_vhdl
COCOTB_RESULTS_FILE ?= results_vhdl.xml
EXTRA_ARGS += --std=08
else
SIM ?= verilator
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(PWD)/../../rtl/mac_unit.sv
SIM_BUILD ?= sim_build_verilog
COCOTB_RESULTS_FILE ?= results_verilog.xml
endif

COCOTB_TOPLEVEL = mac_unit
COCOTB_TEST_MODULES = test_mac_vectors
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
