# Gate-level simulation of the online_softmax sky130 netlists under iverilog.
# Usage: make -C tb/gls all (or lat1 / lat2). PASS = "GLS PASS" in the log.
# Cell models are copied to build/gls_cells with `endif GUARD rewritten to
# `endif // GUARD, which iverilog requires. Override CELLS_SRC=<model dir>.
CELLS_SRC ?= $(HOME)/tools/oss-cad-suite/examples/eqy/spm
REPO      := $(abspath ../..)
BUILD     := $(REPO)/build
CELLS     := $(BUILD)/gls_cells

# UNIT_DELAY empty = zero-delay functional models.
IVFLAGS := -g2005 -DFUNCTIONAL -DUNIT_DELAY=

.PHONY: all lat1 lat2 vectors cells clean

all: lat1 lat2

cells: $(CELLS)/sky130_fd_sc_hd.v

# No prerequisites on CELLS_SRC files, so a bad path gets the message below.
$(CELLS)/sky130_fd_sc_hd.v:
	@test -f "$(CELLS_SRC)/sky130_fd_sc_hd.v" -a -f "$(CELLS_SRC)/primitives.v" || { echo "CELLS_SRC=$(CELLS_SRC): sky130_fd_sc_hd.v/primitives.v not found; set CELLS_SRC=<dir with the PDK cell models> (README, Toolchain paths)"; exit 1; }
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
