MODULE ?= mac_unit
SEED   ?= 1
# All RTL is passed to lint/synth with an explicit top so multi-module
# designs (matmul_tile instantiates mac_unit) elaborate correctly.
SRC    := $(wildcard rtl/*.sv)

# Every recipe runs under bash with pipefail so that `tool | tee log` fails
# when the TOOL fails, not only when tee fails. Without this, a yosys parse
# error, a failed `hierarchy -top`, or a `check -assert` failure was masked
# by tee's exit 0 and synth-check passed on the $_DLATCH_ grep alone
# (2026-09-18 review finding H2).
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

# Every target here is a command, not a file. Without this, the formal/
# directory shadows the formal target (make says "up to date" and silently
# skips sby inside make verify). Found 2026-07-16 during Phase 4.
.PHONY: lint sim coverage synth-check formal verify verify-fw synth-netlist synth-netlist-pipe1 sta sta-pipe1 gls model-check audit-guide evidence-snapshot check-lib

# Unique, immutable EVIDENCE.md row ids: the ledger is append-only and the
# same logical id used to be appended many times, so a citation could not
# say which run it meant (review finding L20). Rows are now suffixed with a
# UTC timestamp; documents cite the exact id.
STAMP := $(shell date -u +%Y%m%dT%H%M%SZ)

lint:
	verilator --lint-only -Wall -sv +incdir+. --top-module $(MODULE) $(SRC)
	verible-verilog-lint $(SRC)

# MODULE= (empty) is required: our MODULE var leaks into the sub-make via
# MAKEFLAGS and cocotb treats legacy MODULE as the Python test-module name,
# clobbering COCOTB_TEST_MODULES. Clearing it lets the tb Makefile's
# COCOTB_TEST_MODULES take effect.
sim:
	$(MAKE) -C tb/$(MODULE) SIM=verilator SEED=$(SEED) MODULE=

# Line coverage counts ONLY verilator t=line records (branch records used to
# be pooled in and masked a below-threshold module, review finding F004);
# documented-unreachable lines are waived through tb/<module>/coverage_waivers.txt.
# PIPE_ROM=1 gates its own artifact (review finding M6).
PIPE_ROM ?= 0
ifeq ($(PIPE_ROM),1)
COV_DAT := coverage_pipe_rom1.dat
else
COV_DAT := coverage.dat
endif
coverage:
	python3 scripts/check_coverage.py --line 90 --func 100 --module $(MODULE) --dat $(COV_DAT)

# build/ is gitignored and absent in a fresh clone; every recipe that writes
# there creates it first (review finding H1: the first documented command,
# make verify MODULE=tool_smoke, died here on a fresh clone).
synth-check:
	@mkdir -p build
	yosys -p 'read_verilog -sv $(SRC); hierarchy -top $(MODULE); proc; opt; check -assert' 2>&1 | tee build/synth.log
	@! grep -q '\$$_DLATCH_' build/synth.log || (echo "INFERRED LATCH" && false)

formal:
	sby -f formal/$(MODULE).sby

verify-fw verify: lint sim coverage synth-check formal
	@mkdir -p build
	@echo "| verify-$(MODULE)-$(STAMP) | $(MODULE) passes lint/sim/cov/synth/formal | PASS | make verify MODULE=$(MODULE) SEED=$(SEED) | 0 |" >> EVIDENCE.md
	@echo "VERIFY OK: $(MODULE)" | tee -a EVIDENCE.md

# Phase 4: map to sky130 cells and run OpenSTA. PERIOD_NS is the target.
# LIB has no sane machine-independent default; override it or stage the
# liberty file at the documented path (README "Toolchain paths").
LIB ?= $(HOME)/tools/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
PERIOD_NS ?= 10

check-lib:
	@test -f "$(LIB)" || { echo "LIB=$(LIB) not found; set LIB=<path to sky130_fd_sc_hd__tt_025C_1v80.lib>"; exit 1; }

synth-netlist: check-lib
	@mkdir -p build
	yosys -p 'read_verilog -sv $(SRC); hierarchy -top $(MODULE); synth -top $(MODULE); dfflibmap -liberty $(LIB); abc -liberty $(LIB); opt_clean; stat -liberty $(LIB); write_verilog -noattr build/$(MODULE)_netlist.v' 2>&1 | tee build/synth_netlist_$(MODULE).log

# The PIPE_ROM=1 online_softmax netlist that tb/gls needs. This used to be a
# hand-typed yosys command in guide.md section 12 only, so README's
# `make -C tb/gls all` was not runnable in order (review finding M4).
synth-netlist-pipe1: check-lib
	@mkdir -p build
	yosys -p 'read_verilog -sv -defer $(SRC); chparam -set PIPE_ROM 1 online_softmax; hierarchy -top online_softmax; synth -top online_softmax; dfflibmap -liberty $(LIB); abc -liberty $(LIB); opt_clean; stat -liberty $(LIB); write_verilog -noattr build/online_softmax_pipe1_netlist.v' 2>&1 | tee build/synth_netlist_online_softmax_pipe1.log

sta: check-lib
	@mkdir -p build
	LIB=$(LIB) NETLIST=build/$(MODULE)_netlist.v MODULE=$(MODULE) PERIOD_NS=$(PERIOD_NS) \
	  opensta -no_init scripts/sta.tcl 2>&1 | tee build/sta_$(MODULE).log

sta-pipe1: check-lib
	@mkdir -p build
	LIB=$(LIB) NETLIST=build/online_softmax_pipe1_netlist.v MODULE=online_softmax PERIOD_NS=$(PERIOD_NS) \
	  opensta -no_init scripts/sta.tcl 2>&1 | tee build/sta_online_softmax_pipe1.log

# Phase 4 GLS of both online_softmax netlists, with the netlists built first.
gls:
	$(MAKE) synth-netlist MODULE=online_softmax
	$(MAKE) synth-netlist-pipe1
	$(MAKE) -C tb/gls all

# Phase 0: golden-model cross-check (attn.py vs attn.cpp bit-identical, and
# the tracked model/exp_lut.hex verified against the generator + sha256 pin).
# The EVIDENCE row is appended only if the check exits 0.
model-check:
	@mkdir -p build/model
	python3 model/crosscheck.py
	@echo "| model-crosscheck-$(STAMP) | attn.py and attn.cpp bit-identical on random + corner cases; tracked exp LUT verified against generator and sha256 pin; float gate met | PASS | make model-check | 0 |" >> EVIDENCE.md
	@echo "VERIFY OK: attn_model" >> EVIDENCE.md

# Claim audit: sentence-level check of hardware/silicon verbs in the claim
# documents (guide.md, README.md, docs/ writeups); see scripts/audit_claims.py.
# The old single grep exempted any LINE containing "pending", so a positive
# board claim on such a line passed (review findings L10/F011).
audit-guide:
	python3 scripts/audit_claims.py

# Snapshot the build/ reports an EVIDENCE row cites into the tracked
# evidence/ tree with sha256 sums, so quoted numbers can be inspected from
# the clone without the toolchain (review finding F014). See evidence/README.md.
evidence-snapshot:
	python3 scripts/evidence_snapshot.py
