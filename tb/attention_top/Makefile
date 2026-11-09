# cocotb testbench for attention_top with verilator line coverage
# (coverage.dat, read by scripts/check_coverage.py).
# coverage.vlt excludes the exp ROM, which tb/online_softmax already covers.
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)
VERILOG_SOURCES = $(PWD)/coverage.vlt \
                   $(PWD)/../../rtl/mac_unit.sv \
                   $(PWD)/../../rtl/matmul_tile.sv \
                   $(PWD)/../../rtl/exp_lut_1p.sv \
                   $(PWD)/../../rtl/sync_ram.sv \
                   $(PWD)/../../rtl/online_softmax.sv \
                   $(PWD)/../../rtl/attention_top.sv

COCOTB_TOPLEVEL = attention_top
COCOTB_TEST_MODULES = test_attention_top

# PIPE_ROM=1 and PV_SPLIT=0 (the FPGA build) run the same tests, each with
# its own build dir, results and coverage file.
PIPE_ROM ?= 0
PV_SPLIT ?= 1
ifeq ($(PV_SPLIT),0)
SIM_BUILD := sim_build_pvsplit0_p$(PIPE_ROM)
COCOTB_RESULTS_FILE := results_pvsplit0_p$(PIPE_ROM).xml
EXTRA_ARGS += -GPV_SPLIT=0 -GPIPE_ROM=$(PIPE_ROM)
COCOTB_PLUSARGS += +verilator+coverage+file+coverage_pvsplit0_p$(PIPE_ROM).dat
else ifeq ($(PIPE_ROM),1)
SIM_BUILD ?= sim_build_pipe_rom1
COCOTB_RESULTS_FILE ?= results_pipe_rom1.xml
EXTRA_ARGS += -GPIPE_ROM=1
COCOTB_PLUSARGS += +verilator+coverage+file+coverage_pipe_rom1.dat
endif

# Repo root, for `include "rtl/exp_lut.svh".
EXTRA_ARGS += +incdir+$(PWD)/../..
EXTRA_ARGS += --coverage-line

SEED ?= 1
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
