MODULE ?= mac_unit
SEED   ?= 1
# All RTL, elaborated with an explicit top (matmul_tile instantiates mac_unit).
SRC    := $(wildcard rtl/*.sv)

# pipefail: `tool | tee log` must fail when the tool fails.
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

# All targets are commands; otherwise the formal/ directory shadows `formal`.
.PHONY: lint sim coverage synth-check formal verify verify-fw record-verify synth-netlist synth-netlist-pipe1 sta sta-pipe1 sta-top gls model-check audit-guide evidence-snapshot check-lib diagrams perl-crosscheck vhdl-crosscheck

# UTC suffix that makes each appended EVIDENCE.md row id unique.
STAMP := $(shell date -u +%Y%m%dT%H%M%SZ)

lint:
	verilator --lint-only -Wall -sv +incdir+. --top-module $(MODULE) $(SRC)
	verible-verilog-lint $(SRC)

# MODULE= clears our MODULE in the sub-make; cocotb would read it as the test module.
sim:
	$(MAKE) -C tb/$(MODULE) SIM=verilator SEED=$(SEED) MODULE=

# Line coverage gate per module; PIPE_ROM=1 gates its own artifact.
PIPE_ROM ?= 0
ifeq ($(PIPE_ROM),1)
COV_DAT := coverage_pipe_rom1.dat
else
COV_DAT := coverage.dat
endif
coverage:
	python3 scripts/check_coverage.py --line 90 --func 100 --module $(MODULE) --dat $(COV_DAT)

# Recipes that write build/ create it first (absent in a fresh clone).
synth-check:
	@mkdir -p build
	yosys -p 'read_verilog -sv $(SRC); hierarchy -top $(MODULE); proc; opt; check -assert' 2>&1 | tee build/synth.log
	@! grep -q '\$$_DLATCH_' build/synth.log || (echo "INFERRED LATCH" && false)

formal:
	sby -f formal/$(MODULE).sby

# VERIFY_NO_LEDGER=1 (CI) runs the same gate without appending to EVIDENCE.md.
verify-fw verify: lint sim coverage synth-check formal record-verify

record-verify:
ifeq ($(VERIFY_NO_LEDGER),1)
	@echo "VERIFY OK: $(MODULE) (ledger row suppressed, VERIFY_NO_LEDGER=1)"
else
	@mkdir -p build
	@echo "| verify-$(MODULE)-$(STAMP) | $(MODULE) passes lint/sim/cov/synth/formal | PASS | make verify MODULE=$(MODULE) SEED=$(SEED) | 0 |" >> EVIDENCE.md
	@echo "VERIFY OK: $(MODULE)" | tee -a EVIDENCE.md
endif

# sky130 liberty (override LIB or stage it at this path) and the target clock period.
LIB ?= $(HOME)/tools/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
PERIOD_NS ?= 10

check-lib:
	@test -f "$(LIB)" || { echo "LIB=$(LIB) not found; set LIB=<path to sky130_fd_sc_hd__tt_025C_1v80.lib>"; exit 1; }

# Timing-driven mapping: flattened Booth synthesis with Kogge-Stone adders, then ABC with a
# delay target from PERIOD_NS plus buffering and sizing (scripts/abc_timing.abc).
SYNTH_FAST = synth -booth -flatten -top $(1) -run :fine; techmap -map +/techmap.v -map +/choices/kogge-stone.v; synth -booth -flatten -top $(1) -run fine:;
ABC_PS      = $(shell awk 'BEGIN{printf "%d", $(PERIOD_NS)*1000}')
ABC_SCRIPT  = build/abc_timing_$(ABC_PS).abc
ABC_MAP     = abc -D $(ABC_PS) -script $(ABC_SCRIPT) -liberty $(LIB)
# NETLIST_SRC lets sta-top swap in the SRAM stand-in; CHPARAM sets parameters before elaboration.
NETLIST_SRC ?= $(SRC)
CHPARAM     ?=
$(ABC_SCRIPT): scripts/abc_timing.abc
	@mkdir -p build
	sed 's/{D}/$(ABC_PS)/g' $< > $@

# setattr puts keep on the flops of (* keep *) registers so opt_merge cannot fold the duplicates.
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

# Top-level STA of attention_top (PIPE_ROM=1) with scripts/sync_ram_sta_stub.sv standing in
# for the SRAM macros (macro access time not modeled), then summarized.
TOP_STA_SRC = $(filter-out rtl/sync_ram.sv,$(SRC)) scripts/sync_ram_sta_stub.sv
sta-top: check-lib
	$(MAKE) synth-netlist MODULE=attention_top PERIOD_NS=$(PERIOD_NS) NETLIST_SRC="$(TOP_STA_SRC)" CHPARAM="chparam -set PIPE_ROM 1 attention_top;"
	$(MAKE) sta MODULE=attention_top PERIOD_NS=$(PERIOD_NS)
	python3 scripts/sta_summary.py build/sta_attention_top.log --period $(PERIOD_NS) --netlist build/attention_top_netlist.v --out build/sta_attention_top_summary.txt

# GLS of both online_softmax netlists, with the netlists built first.
gls:
	$(MAKE) synth-netlist MODULE=online_softmax
	$(MAKE) synth-netlist-pipe1
	$(MAKE) -C tb/gls all

# Golden-model cross-check (attn.py vs attn.cpp, LUT pin); the row is appended only on exit 0.
model-check:
	@mkdir -p build/model
	python3 model/crosscheck.py
ifneq ($(VERIFY_NO_LEDGER),1)
	@echo "| model-crosscheck-$(STAMP) | attn.py and attn.cpp bit-identical on random + corner cases; tracked exp LUT verified against generator and sha256 pin; float gate met | PASS | make model-check | 0 |" >> EVIDENCE.md
	@echo "VERIFY OK: attn_model" >> EVIDENCE.md
endif

# Clause-level audit of hardware/silicon claims in the claim documents.
audit-guide:
	python3 scripts/audit_claims.py

# Copy cited build/ reports into tracked evidence/reports/ (see evidence/README.md).
evidence-snapshot:
	python3 scripts/evidence_snapshot.py

# Render the WaveDrom diagram with the pinned CLI (needs npx); output is committed.
diagrams:
	npx --yes wavedrom-cli@3.1.1 -i docs/wavedrom/drain_overlap.json -s docs/img/drain_overlap.svg
	@echo "rendered docs/img/drain_overlap.svg"

# Perl ports must match the Python originals byte for byte.
perl-crosscheck:
	python3 scripts/perl_crosscheck.py

# Replay the same vectors through the VHDL (GHDL) and SV (verilator) mac_unit; traces must
# match each other and the Python mirror.
vhdl-crosscheck:
	$(MAKE) -C tb/vhdl_mac LANG=vhdl MODULE=
	$(MAKE) -C tb/vhdl_mac LANG=verilog MODULE=
	python3 scripts/gen_mac_vectors.py --check tb/vhdl_mac/trace_vhdl.txt
	python3 scripts/gen_mac_vectors.py --check tb/vhdl_mac/trace_verilog.txt
	cmp tb/vhdl_mac/trace_vhdl.txt tb/vhdl_mac/trace_verilog.txt && echo "VHDL CROSSCHECK PASS: traces identical"
