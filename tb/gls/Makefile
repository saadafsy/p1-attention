# Phase 4 gate-level simulation of the online_softmax sky130 netlists.
# Run from THIS directory: make -C tb/gls all   (or lat1 / lat2 alone)
#
# Flow per config: scripts/gen_gls_vectors.py emits one shared stimulus file
# plus a spec-derived expected-port file per latency (see that script's
# header); gls_tb.v replays them against the netlist under iverilog with the
# sky130_fd_sc_hd FUNCTIONAL cell models and dumps a VCD (consumed again by
# the Phase 5 switching-activity comparison). PASS = "GLS PASS ... 0 errors"
# in the log, grepped below.
#
# Cell models: the PDK-distributed sky130_fd_sc_hd.v + primitives.v bundled
# with oss-cad-suite (eqy example). Two mechanical fixes are needed for
# iverilog and applied to a LOCAL COPY in build/gls_cells (source untouched):
#   1. `endif SOME_GUARD   ->  `endif // SOME_GUARD   (bare trailing token
#      after `endif is rejected by iverilog)
#   2. UNIT_DELAY defined empty (the models leave it undefined; empty is the
#      zero-delay functional intent)
CELLS_SRC := $(HOME)/tools/oss-cad-suite/examples/eqy/spm
REPO      := $(abspath ../..)
BUILD     := $(REPO)/build
CELLS     := $(BUILD)/gls_cells
NCYC      := $(shell wc -l < $(BUILD)/gls_stim.hex 2>/dev/null || echo 0)

IVFLAGS := -g2005 -DFUNCTIONAL -DUNIT_DELAY=

.PHONY: all lat1 lat2 vectors cells clean

all: lat1 lat2

cells: $(CELLS)/sky130_fd_sc_hd.v

$(CELLS)/sky130_fd_sc_hd.v: $(CELLS_SRC)/sky130_fd_sc_hd.v $(CELLS_SRC)/primitives.v
	mkdir -p $(CELLS)
	sed -E 's/^(`endif)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$$/\1 \/\/ \2/' \
	  $(CELLS_SRC)/sky130_fd_sc_hd.v > $(CELLS)/sky130_fd_sc_hd.v
	sed -E 's/^(`endif)[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$$/\1 \/\/ \2/' \
	  $(CELLS_SRC)/primitives.v > $(CELLS)/primitives.v

vectors:
	cd $(REPO) && python3 scripts/gen_gls_vectors.py

lat1: cells vectors
	iverilog $(IVFLAGS) -o $(BUILD)/gls_lat1.vvp -s gls_tb \
	  $(CELLS)/primitives.v $(CELLS)/sky130_fd_sc_hd.v \
	  $(BUILD)/online_softmax_netlist.v gls_tb.v
	vvp $(BUILD)/gls_lat1.vvp +stim=$(BUILD)/gls_stim.hex \
	  +exp=$(BUILD)/gls_expected_lat1.hex +n=$$(wc -l < $(BUILD)/gls_stim.hex) \
	  +vcd=$(BUILD)/gls_lat1.vcd | tee $(BUILD)/gls_lat1.log
	grep -q "GLS PASS" $(BUILD)/gls_lat1.log

lat2: cells vectors
	iverilog $(IVFLAGS) -o $(BUILD)/gls_lat2.vvp -s gls_tb \
	  $(CELLS)/primitives.v $(CELLS)/sky130_fd_sc_hd.v \
	  $(BUILD)/online_softmax_pipe1_netlist.v gls_tb.v
	vvp $(BUILD)/gls_lat2.vvp +stim=$(BUILD)/gls_stim.hex \
	  +exp=$(BUILD)/gls_expected_lat2.hex +n=$$(wc -l < $(BUILD)/gls_stim.hex) \
	  +vcd=$(BUILD)/gls_lat2.vcd | tee $(BUILD)/gls_lat2.log
	grep -q "GLS PASS" $(BUILD)/gls_lat2.log

clean:
	rm -rf $(CELLS) $(BUILD)/gls_*.vvp $(BUILD)/gls_*.vcd $(BUILD)/gls_*.log
