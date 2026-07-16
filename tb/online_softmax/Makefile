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
COCOTB_TEST_MODULES = test_online_softmax

EXTRA_ARGS += +incdir+$(PWD)/../..
EXTRA_ARGS += --coverage-line

SEED ?= 1
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
