MODULE ?= mac_unit
SEED   ?= 1
# All RTL is passed to lint/synth with an explicit top so multi-module
# designs (matmul_tile instantiates mac_unit) elaborate correctly.
SRC    := $(wildcard rtl/*.sv)

# Every target here is a command, not a file. Without this, the formal/
# directory shadows the formal target (make says "up to date" and silently
# skips sby inside make verify). Found 2026-07-16 during Phase 4.
.PHONY: lint sim coverage synth-check formal verify verify-fw synth-netlist sta model-check audit-guide

lint:
	verilator --lint-only -Wall -sv --top-module $(MODULE) $(SRC)
	verible-verilog-lint $(SRC)

# MODULE= (empty) is required: our MODULE var leaks into the sub-make via
# MAKEFLAGS and cocotb treats legacy MODULE as the Python test-module name,
# clobbering COCOTB_TEST_MODULES. Clearing it lets the tb Makefile's
# COCOTB_TEST_MODULES take effect.
sim:
	$(MAKE) -C tb/$(MODULE) SIM=verilator SEED=$(SEED) MODULE=

coverage:
	python3 scripts/check_coverage.py --line 90 --func 100 --module $(MODULE)

synth-check:
	yosys -p 'read_verilog -sv $(SRC); hierarchy -top $(MODULE); proc; opt; check -assert' 2>&1 | tee build/synth.log
	@! grep -q '\$$_DLATCH_' build/synth.log || (echo "INFERRED LATCH" && false)

formal:
	sby -f formal/$(MODULE).sby

verify-fw verify: lint sim coverage synth-check formal
	@mkdir -p build
	@echo "| verify-$(MODULE) | $(MODULE) passes lint/sim/cov/synth/formal | PASS | make verify MODULE=$(MODULE) | 0 |" >> EVIDENCE.md
	@echo "VERIFY OK: $(MODULE)" | tee -a EVIDENCE.md

# Phase 4: map to sky130 cells and run OpenSTA. PERIOD_NS is the target.
LIB ?= $(HOME)/tools/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
PERIOD_NS ?= 10

synth-netlist:
	@mkdir -p build
	yosys -p 'read_verilog -sv $(SRC); hierarchy -top $(MODULE); synth -top $(MODULE); dfflibmap -liberty $(LIB); abc -liberty $(LIB); opt_clean; stat -liberty $(LIB); write_verilog -noattr build/$(MODULE)_netlist.v' 2>&1 | tee build/synth_netlist_$(MODULE).log

sta:
	LIB=$(LIB) NETLIST=build/$(MODULE)_netlist.v MODULE=$(MODULE) PERIOD_NS=$(PERIOD_NS) \
	  opensta -no_init scripts/sta.tcl 2>&1 | tee build/sta_$(MODULE).log

# Phase 0: golden-model cross-check (attn.py vs attn.cpp bit-identical).
# The EVIDENCE row is appended only if the check exits 0.
model-check:
	@mkdir -p build/model
	python3 model/crosscheck.py
	@echo "| model-crosscheck | attn.py and attn.cpp bit-identical on random + corner cases; exp LUT emitted; float gate met | PASS | make model-check | 0 |" >> EVIDENCE.md
	@echo "VERIFY OK: attn_model" >> EVIDENCE.md

audit-guide:
	@test -f guide.md || (echo "no guide.md yet" && exit 1)
	@if grep -niE 'taped out|on the (real )?board|runs on the fpga|measured on|soldered|powered on' guide.md \
	   | grep -viE 'pending|not (yet )?(implemented|taped|fabricated)|in simulation|renode' ; then \
	   echo "audit-guide: unbacked hardware/silicon claim found"; exit 1; \
	 else echo "audit-guide: clean"; fi
