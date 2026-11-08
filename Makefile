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
.PHONY: lint sim coverage synth-check formal verify verify-fw record-verify synth-netlist synth-netlist-pipe1 sta sta-pipe1 sta-top gls model-check audit-guide evidence-snapshot check-lib diagrams perl-crosscheck vhdl-crosscheck

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

# VERIFY_NO_LEDGER=1 (CI) runs the identical gate but does not append to
# EVIDENCE.md, so a hosted runner never mutates the checkout; the ledger row
# is appended only by a run on a machine whose result the owner commits.
verify-fw verify: lint sim coverage synth-check formal record-verify

record-verify:
ifeq ($(VERIFY_NO_LEDGER),1)
	@echo "VERIFY OK: $(MODULE) (ledger row suppressed, VERIFY_NO_LEDGER=1)"
else
	@mkdir -p build
	@echo "| verify-$(MODULE)-$(STAMP) | $(MODULE) passes lint/sim/cov/synth/formal | PASS | make verify MODULE=$(MODULE) SEED=$(SEED) | 0 |" >> EVIDENCE.md
	@echo "VERIFY OK: $(MODULE)" | tee -a EVIDENCE.md
endif

# Phase 4: map to sky130 cells and run OpenSTA. PERIOD_NS is the target.
# LIB has no sane machine-independent default; override it or stage the
# liberty file at the documented path (README "Toolchain paths").
LIB ?= $(HOME)/tools/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
PERIOD_NS ?= 10

check-lib:
	@test -f "$(LIB)" || { echo "LIB=$(LIB) not found; set LIB=<path to sky130_fd_sc_hd__tt_025C_1v80.lib>"; exit 1; }

# Mapping is timing-driven: Booth multipliers (synth -booth) and ABC with a
# delay target plus buffering and gate sizing (scripts/abc_timing.abc,
# with {D} filled in from PERIOD_NS). The earlier flow mapped area-only
# with minimum-size cells and no buffers, so unbuffered fanout alone cost
# several ns per path, and hundreds at the top level (2026-11-08).
# NETLIST_SRC lets sta-top swap the SRAM stand-in in for rtl/sync_ram.sv;
# CHPARAM sets parameters before elaboration. Registers declared (* keep *)
# (deliberate duplicates for fanout) get keep on their flops, not just the
# wire, so opt_merge does not fold them back into one.
# Generic synthesis with Booth multipliers, flattened (so ABC sees whole
# nets for buffering), adders as Kogge-Stone parallel-prefix instead of the
# default ripple carry.
SYNTH_FAST = synth -booth -flatten -top $(1) -run :fine; techmap -map +/techmap.v -map +/choices/kogge-stone.v; synth -booth -flatten -top $(1) -run fine:;
ABC_PS      = $(shell awk 'BEGIN{printf "%d", $(PERIOD_NS)*1000}')
ABC_SCRIPT  = build/abc_timing_$(ABC_PS).abc
ABC_MAP     = abc -D $(ABC_PS) -script $(ABC_SCRIPT) -liberty $(LIB)
NETLIST_SRC ?= $(SRC)
CHPARAM     ?=
$(ABC_SCRIPT): scripts/abc_timing.abc
	@mkdir -p build
	sed 's/{D}/$(ABC_PS)/g' $< > $@

synth-netlist: check-lib $(ABC_SCRIPT)
	@mkdir -p build
	yosys -p 'read_verilog -sv -defer $(NETLIST_SRC); $(CHPARAM) hierarchy -top $(MODULE); proc; setattr -set keep 1 a:keep %ci1 c:* %i; $(call SYNTH_FAST,$(MODULE)) dfflibmap -liberty $(LIB); $(ABC_MAP); opt_clean; stat -liberty $(LIB); write_verilog -noattr build/$(MODULE)_netlist.v' 2>&1 | tee build/synth_netlist_$(MODULE).log
	@# OpenSTA's Verilog reader rejects 'signed' on ports/wires (Yosys 0.69 emits it); a gate netlist does not need it.
	@sed -i -E 's/^(  (input|output|inout|wire)) signed /\1 /' build/$(MODULE)_netlist.v

# The PIPE_ROM=1 online_softmax netlist that tb/gls needs.
synth-netlist-pipe1: check-lib $(ABC_SCRIPT)
	@mkdir -p build
	yosys -p 'read_verilog -sv -defer $(SRC); chparam -set PIPE_ROM 1 online_softmax; hierarchy -top online_softmax; $(call SYNTH_FAST,online_softmax) dfflibmap -liberty $(LIB); $(ABC_MAP); opt_clean; stat -liberty $(LIB); write_verilog -noattr build/online_softmax_pipe1_netlist.v' 2>&1 | tee build/synth_netlist_online_softmax_pipe1.log
	@# OpenSTA's Verilog reader rejects 'signed' on ports/wires (Yosys 0.69 emits it); a gate netlist does not need it.
	@sed -i -E 's/^(  (input|output|inout|wire)) signed /\1 /' build/online_softmax_pipe1_netlist.v

sta: check-lib
	@mkdir -p build
	LIB=$(LIB) NETLIST=build/$(MODULE)_netlist.v MODULE=$(MODULE) PERIOD_NS=$(PERIOD_NS) \
	  opensta -no_init scripts/sta.tcl 2>&1 | tee build/sta_$(MODULE).log

sta-pipe1: check-lib
	@mkdir -p build
	LIB=$(LIB) NETLIST=build/online_softmax_pipe1_netlist.v MODULE=online_softmax PERIOD_NS=$(PERIOD_NS) \
	  opensta -no_init scripts/sta.tcl 2>&1 | tee build/sta_online_softmax_pipe1.log

# Top-level STA: the whole engine (PIPE_ROM=1, PV_SPLIT=1, the standard-cell
# configuration) synthesized to sky130 cells and timed, then summarized (WNS,
# worst path, owning block). The four memories are SRAM macros in an ASIC,
# so scripts/sync_ram_sta_stub.sv stands in for rtl/sync_ram.sv: a flop at
# every macro pin, macro access time not modeled (no sky130 SRAM liberty
# in this flow). Flattening them into 32k flip-flops instead is what gave
# the earlier, meaningless -526 ns.
TOP_STA_SRC = $(filter-out rtl/sync_ram.sv,$(SRC)) scripts/sync_ram_sta_stub.sv
sta-top: check-lib
	$(MAKE) synth-netlist MODULE=attention_top PERIOD_NS=$(PERIOD_NS) NETLIST_SRC="$(TOP_STA_SRC)" CHPARAM="chparam -set PIPE_ROM 1 attention_top;"
	$(MAKE) sta MODULE=attention_top PERIOD_NS=$(PERIOD_NS)
	python3 scripts/sta_summary.py build/sta_attention_top.log --period $(PERIOD_NS) --netlist build/attention_top_netlist.v --out build/sta_attention_top_summary.txt

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
ifneq ($(VERIFY_NO_LEDGER),1)
	@echo "| model-crosscheck-$(STAMP) | attn.py and attn.cpp bit-identical on random + corner cases; tracked exp LUT verified against generator and sha256 pin; float gate met | PASS | make model-check | 0 |" >> EVIDENCE.md
	@echo "VERIFY OK: attn_model" >> EVIDENCE.md
endif

# Claim audit: sentence-level check of hardware/silicon verbs in the claim
# documents (docs/guide.md, README.md, docs/ writeups); see scripts/audit_claims.py.
# The old single grep exempted any LINE containing "pending", so a positive
# board claim on such a line passed (review findings L10/F011).
audit-guide:
	python3 scripts/audit_claims.py

# Snapshot the build/ reports an EVIDENCE row cites into the tracked
# evidence/ tree with sha256 sums, so quoted numbers can be inspected from
# the clone without the toolchain (review finding F014). See evidence/README.md.
evidence-snapshot:
	python3 scripts/evidence_snapshot.py

# Diagrams: Mermaid blocks in docs/diagrams.md render on GitHub as-is; the
# WaveDrom timing diagram is rendered from its JSON source with the pinned
# CLI (needs node/npx). Output is committed under docs/img/.
diagrams:
	npx --yes wavedrom-cli@3.1.1 -i docs/wavedrom/drain_overlap.json -s docs/img/drain_overlap.svg
	@echo "rendered docs/img/drain_overlap.svg"

# Perl ports (scripts/*.pl) must agree with the Python originals byte for
# byte on the same stimulus; this is their evidence gate (2026-09-19).
perl-crosscheck:
	python3 scripts/perl_crosscheck.py

# VHDL port of mac_unit (rtl_vhdl/, target-scores change 9): the SAME golden
# vector file replayed through the VHDL (GHDL) and the SystemVerilog
# (verilator) implementations by one cocotb test; the two observed traces
# must be byte-identical and each must match the Python mirror. Needs ghdl
# and verilator (both in oss-cad-suite). Never run where this was written.
vhdl-crosscheck:
	$(MAKE) -C tb/vhdl_mac LANG=vhdl MODULE=
	$(MAKE) -C tb/vhdl_mac LANG=verilog MODULE=
	python3 scripts/gen_mac_vectors.py --check tb/vhdl_mac/trace_vhdl.txt
	python3 scripts/gen_mac_vectors.py --check tb/vhdl_mac/trace_verilog.txt
	cmp tb/vhdl_mac/trace_vhdl.txt tb/vhdl_mac/trace_verilog.txt && echo "VHDL CROSSCHECK PASS: traces identical"
