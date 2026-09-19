# cocotb testbench for attention_top (Phase 2 integration). Real verilator
# line coverage is enabled; coverage.dat is written to this directory and
# picked up by scripts/check_coverage.py from the repo root.
#
# VERILOG_SOURCES lists all four RTL files in dependency order (mac_unit is
# instantiated by matmul_tile; matmul_tile and online_softmax are both
# instantiated by attention_top). coverage.vlt is listed FIRST: it is a
# `verilator_config coverage_off directive (see coverage.vlt for the full
# rationale: the exp_lut.svh ROM is already exhaustively covered and
# equivalence-proven standalone in tb/online_softmax, so re-sweeping its
# 1024 case arms through 4 lane instances here would only poison this
# module's own coverage gate). Verilator applies `verilator_config
# directives regardless of file order in the invocation, but listing it
# first keeps the Makefile's intent readable.
#
# The `include "rtl/exp_lut.svh" line inside online_softmax.sv is
# repo-root relative (docs/uarch.md 8.2), so +incdir+$(PWD)/../.. hands
# verilator an include dir that IS the repo root; `include "rtl/exp_lut.svh"
# then resolves to <repo_root>/rtl/exp_lut.svh, which exists (same fix as
# tb/online_softmax/Makefile).
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)
VERILOG_SOURCES = $(PWD)/coverage.vlt \
                   $(PWD)/../../rtl/mac_unit.sv \
                   $(PWD)/../../rtl/matmul_tile.sv \
                   $(PWD)/../../rtl/exp_lut_2p.sv \
                   $(PWD)/../../rtl/online_softmax.sv \
                   $(PWD)/../../rtl/attention_top.sv

COCOTB_TOPLEVEL = attention_top
COCOTB_TEST_MODULES = test_attention_top

# PIPE_ROM knob (2026-09-19): attention_top forwards PIPE_ROM to its
# online_softmax lanes and absorbs the extra cycle internally, so the SAME
# test module (same golden compare, same cycle formula) must pass in both
# elaborations. Artifact-isolated exactly like tb/online_softmax.
PIPE_ROM ?= 0
ifeq ($(PIPE_ROM),1)
SIM_BUILD ?= sim_build_pipe_rom1
COCOTB_RESULTS_FILE ?= results_pipe_rom1.xml
EXTRA_ARGS += -GPIPE_ROM=1
COCOTB_PLUSARGS += +verilator+coverage+file+coverage_pipe_rom1.dat
endif

EXTRA_ARGS += +incdir+$(PWD)/../..
EXTRA_ARGS += --coverage-line

SEED ?= 1
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
