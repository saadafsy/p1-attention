# cocotb testbench for online_softmax with verilator line coverage
# (coverage.dat, read by scripts/check_coverage.py).
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)
# exp_lut_1p.sv is only instantiated when PIPE_ROM=1.
VERILOG_SOURCES = $(PWD)/../../rtl/exp_lut_1p.sv \
                   $(PWD)/../../rtl/online_softmax.sv

COCOTB_TOPLEVEL = online_softmax

# PIPE_ROM=1 (latency-2 ROM) runs its own test module with separate build dir,
# results and coverage file so it never clobbers the default run's artifacts.
PIPE_ROM ?= 0

ifeq ($(PIPE_ROM),1)
COCOTB_TEST_MODULES = test_softmax_pipe_rom
SIM_BUILD ?= sim_build_pipe_rom1
COCOTB_RESULTS_FILE ?= results_pipe_rom1.xml
EXTRA_ARGS += -GPIPE_ROM=1
COCOTB_PLUSARGS += +verilator+coverage+file+coverage_pipe_rom1.dat
# Excludes the ROM from coverage (see coverage_pipe_rom1.vlt).
VERILOG_SOURCES := $(PWD)/coverage_pipe_rom1.vlt $(VERILOG_SOURCES)
else
COCOTB_TEST_MODULES = test_online_softmax,test_softmax_coverage
endif

# Repo root, for `include "rtl/exp_lut.svh".
EXTRA_ARGS += +incdir+$(PWD)/../..
EXTRA_ARGS += --coverage-line

SEED ?= 1
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
