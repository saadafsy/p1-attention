# matmul_tile UVM environment (target-scores change 1, added 2026-09-19).
# Run from the repo root: make -C tb/uvm <target>. Needs Vivado xsim on PATH
# (source <Vivado>/settings64.sh); nothing here runs under verilator.
#
# Targets
#   vectors    python: golden vector file for SEED (scripts/gen_tile_uvm_vectors.py)
#   smoke      replay test, one seed: the compile/run/coverage-switch sanity run
#   replay     replay test for SEED, scoreboard vs Python golden, in-sim
#   random     SV constrained-random test for SEED, then the Python mirror
#              checks the monitor's trace file (no SV reference model exists)
#   regress    UVM_SEEDS seeds of both tests, then merged coverage (xcrg)
#   bug-proof  compile mac_unit with +define+INJECT_BUG and REQUIRE the replay
#              test to fail: the proof that the environment catches a bug
#   gate       the whole evidence gate: regress + bug-proof
#
# Status: never run (no Vivado where this was written). The gate must be
# observed on a real install before any UVM claim is made; see README.md.
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
SEED ?= 17
UVM_SEEDS ?= 10
NUM_DOTS ?= 100
ROOT := $(abspath ../..)
OUT := $(ROOT)/build/uvm
VEC := vectors/tile_seed_$(SEED).txt
RUN := bash scripts/run_xsim.sh

.PHONY: vectors smoke replay random regress bug-proof gate clean check

vectors:
	python3 $(ROOT)/scripts/gen_tile_uvm_vectors.py --emit $(SEED) $(VEC) --dots 200

$(VEC):
	python3 $(ROOT)/scripts/gen_tile_uvm_vectors.py --emit $(SEED) $(VEC) --dots 200

smoke: $(VEC)
	$(RUN) tile_replay_test $(SEED) $(OUT)/smoke +VECTOR_FILE=$(abspath $(VEC))

replay: $(VEC)
	$(RUN) tile_replay_test $(SEED) $(OUT)/seed_$(SEED)_replay +VECTOR_FILE=$(abspath $(VEC))

random:
	$(RUN) tile_random_test $(SEED) $(OUT)/seed_$(SEED)_random +NUM_DOTS=$(NUM_DOTS) +TRACE_FILE=$(OUT)/seed_$(SEED)_random/trace.txt
	python3 $(ROOT)/scripts/gen_tile_uvm_vectors.py --check $(OUT)/seed_$(SEED)_random/trace.txt

# N seeds of each test; every seed has its own vector file and coverage db.
regress:
	@set -e; for s in $$(seq 1 $(UVM_SEEDS)); do \
	  $(MAKE) --no-print-directory replay SEED=$$s; \
	  $(MAKE) --no-print-directory random SEED=$$s; \
	done
	bash scripts/merge_coverage.sh $(OUT)

# Negative test: with the deliberate mac_unit mutation compiled in
# (rtl/mac_unit.sv `ifdef INJECT_BUG: the load row ignores clr, so a new
# dot product accumulates onto the previous one), the replay scoreboard
# MUST report mismatches and xsim MUST exit nonzero. If it exits zero the
# environment is not checking, and this target fails.
bug-proof: $(VEC)
	@if $(RUN) tile_replay_test $(SEED) $(OUT)/bug_proof +VECTOR_FILE=$(abspath $(VEC)) --define INJECT_BUG; then \
	  echo "BUG-PROOF FAIL: the injected bug was NOT caught"; exit 1; \
	else \
	  grep -q "acc(.*): dut=.* golden=" $(OUT)/bug_proof/xsim.log && echo "BUG-PROOF PASS: injected bug caught by the scoreboard"; \
	fi

gate: regress bug-proof
	@echo "UVM GATE PASS: regress ($(UVM_SEEDS) seeds x 2 tests) + merged coverage + injected bug caught"

clean:
	rm -rf $(OUT) xsim.dir *.log *.jou *.pb *.wdb
