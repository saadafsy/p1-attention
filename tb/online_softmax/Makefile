# cocotb testbench for online_softmax. Real verilator line coverage is
# enabled; coverage.dat is written to this directory and picked up by
# scripts/check_coverage.py from the repo root.
#
# Self-contained module: the RTL is `include-based (rtl/online_softmax.sv
# `include "rtl/exp_lut.svh", docs/uarch.md 8.2), NOT a second Verilog
# source, so VERILOG_SOURCES lists only online_softmax.sv. The include path
# is written repo-root-relative in the RTL, so we hand verilator an
# incdir that IS the repo root; `include "rtl/exp_lut.svh" then resolves as
# <repo_root>/rtl/exp_lut.svh, which exists. Verified directly: dropping
# this EXTRA_ARGS line reproduces a "No such file or directory" from
# verilator on the `include line, confirming this is the flag doing the
# resolution (not some other default include path).
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)
VERILOG_SOURCES = $(PWD)/../../rtl/online_softmax.sv

COCOTB_TOPLEVEL = online_softmax

# PIPE_ROM config knob (Phase 4, docs/uarch.md 8.2.1). Default 0 = today's
# invocation, byte-for-byte: same COCOTB_TEST_MODULES, same SIM_BUILD
# (sim_build), same COCOTB_RESULTS_FILE (results.xml), same coverage.dat
# path -- these are exactly the artifacts scripts/check_coverage.py's
# `**/coverage.dat` glob and EVIDENCE.md's func_coverage.txt reference, so
# `make verify` / `make coverage` must see them unchanged.
#
# PIPE_ROM=1 elaborates the registered-ROM (latency-2) variant via a
# verilator elaboration-time parameter override (-GPIPE_ROM=1) and runs a
# separate, latency-2-aware test module. To guarantee a PIPE_ROM=1 run can
# NEVER clobber the default run's artifacts (even if invoked back-to-back in
# either order), it is redirected to its own build directory, its own
# COCOTB_RESULTS_FILE, and -- since verilator writes its coverage dump only
# via a RUNTIME +plusarg, not a compile-time flag -- its own coverage.dat
# filename via +verilator+coverage+file+<name>. None of these three paths
# collide with the default run's sim_build/, results.xml, or coverage.dat.
PIPE_ROM ?= 0

ifeq ($(PIPE_ROM),1)
COCOTB_TEST_MODULES = test_softmax_pipe_rom
SIM_BUILD ?= sim_build_pipe_rom1
COCOTB_RESULTS_FILE ?= results_pipe_rom1.xml
EXTRA_ARGS += -GPIPE_ROM=1
COCOTB_PLUSARGS += +verilator+coverage+file+coverage_pipe_rom1.dat
else
COCOTB_TEST_MODULES = test_online_softmax,test_softmax_coverage
endif

EXTRA_ARGS += +incdir+$(PWD)/../..
EXTRA_ARGS += --coverage-line

SEED ?= 1
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
