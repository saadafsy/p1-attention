# matmul_tile UVM environment: make -C tb/uvm <target> [SIM=xsim|verilator].
#   vectors    golden vector file for SEED
#   smoke      one replay run (compile/run sanity)
#   replay     replay test for SEED, scoreboard vs Python golden
#   random     constrained-random test, trace checked by the Python mirror
#   regress    UVM_SEEDS seeds of both tests, then merged coverage (xsim only)
#   bug-proof  replay with INJECT_BUG compiled in must fail
#   gate       regress + bug-proof
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
SEED ?= 17
UVM_SEEDS ?= 10
NUM_DOTS ?= 100
ROOT := $(abspath ../..)
OUT := $(ROOT)/build/uvm
VEC := vectors/tile_seed_$(SEED).txt
SIM ?= xsim
ifeq ($(SIM),verilator)
# Verilator + upstream UVM 2017: no merged coverage.
RUN := bash scripts/run_verilator.sh
LOG := sim.log
else
RUN := bash scripts/run_xsim.sh
LOG := xsim.log
endif

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

# Each seed gets its own vector file and coverage db.
regress:
	@set -e; for s in $$(seq 1 $(UVM_SEEDS)); do \
	  $(MAKE) --no-print-directory replay SEED=$$s; \
	  $(MAKE) --no-print-directory random SEED=$$s; \
	done
ifeq ($(SIM),verilator)
	@echo "merged coverage NOT run (SIM=verilator has no coverage merge)"
else
	bash scripts/merge_coverage.sh $(OUT)
endif

# INJECT_BUG makes mac_unit's load ignore clr; the run must fail with scoreboard mismatches.
bug-proof: $(VEC)
ifeq ($(SIM),verilator)
	@# leg 1: full environment (scoreboard + SVA); leg 2: scoreboard alone. Both MUST fail.
	@if $(RUN) tile_replay_test $(SEED) $(OUT)/bug_proof +VECTOR_FILE=$(abspath $(VEC)) --define INJECT_BUG; then 	  echo "BUG-PROOF FAIL: the injected bug was NOT caught (scoreboard + SVA)"; exit 1; 	else echo "BUG-PROOF leg 1: caught with SVA enabled"; fi
	@if $(RUN) tile_replay_test $(SEED) $(OUT)/bug_proof_sb_only +VECTOR_FILE=$(abspath $(VEC)) --define INJECT_BUG --no-sva; then 	  echo "BUG-PROOF FAIL: the scoreboard alone did NOT catch the injected bug"; exit 1; 	else grep -q "acc(.*): dut=.* golden=" $(OUT)/bug_proof_sb_only/$(LOG) 	  && echo "BUG-PROOF PASS: injected bug caught by the scoreboard alone and by the SVA"; fi
else
	@if $(RUN) tile_replay_test $(SEED) $(OUT)/bug_proof +VECTOR_FILE=$(abspath $(VEC)) --define INJECT_BUG; then 	  echo "BUG-PROOF FAIL: the injected bug was NOT caught"; exit 1; 	else 	  grep -q "acc(.*): dut=.* golden=" $(OUT)/bug_proof/$(LOG) && echo "BUG-PROOF PASS: injected bug caught by the scoreboard"; 	fi
endif

gate: regress bug-proof
	@echo "UVM GATE PASS ($(SIM)): regress ($(UVM_SEEDS) seeds x 2 tests) + injected bug caught$(if $(filter verilator,$(SIM)), (merged coverage NOT run),  + merged coverage)"

clean:
	rm -rf $(OUT) xsim.dir *.log *.jou *.pb *.wdb
