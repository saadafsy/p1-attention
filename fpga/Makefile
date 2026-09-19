# FPGA bring-up targets (target-scores change 2, added 2026-09-19).
# BOARD=basys3 (default, XC7A35T, fpga/basys3.xdc) or BOARD=nexys_a7
# (XC7A100T, fpga/nexys_a7_100t.xdc); the RTL is identical, only the part
# and the pins differ. Run from the repo root: make -C fpga <target>. Needs
# Vivado on PATH (source <Vivado>/settings64.sh) and, from `program` on,
# the board on USB. Every target is a gate step of docs/phase6_fpga_guide.md
# section 0; nothing here has been run yet (PENDING-HARDWARE).
#
#   bitstream   build at F_MHZ (default 100): synth, timing gate (fails on
#               WNS<0), the exp-ROM block-RAM gate, place, route, .bit
#   program     load the F_MHZ bitstream over JTAG
#   hw-test     the self-checking host test against model/attn.py (PORT=)
#   sweep       rebuild/program/test at each FREQS; writes build/fpga/sweep.csv
#   hw-gate     bitstream + program + hw-test at 100 MHz, then sweep: the
#               evidence gate for every PENDING-HARDWARE row
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
ROOT := $(abspath ..)
BOARD ?= basys3
F_MHZ ?= 100
PORT ?= /dev/ttyUSB1
FREQS ?= 50,75,100,110,125
N ?= 16
OUT := $(ROOT)/build/fpga/f$(F_MHZ)
# VCO fixed at 1000 MHz: out_div = 1000 / F_MHZ, clk_hz = F_MHZ * 1e6
OUT_DIV := $(shell python3 -c "print(1000/$(F_MHZ))")
CLK_HZ := $(shell python3 -c "print(int($(F_MHZ)*1000000))")

.PHONY: bitstream program hw-test sweep hw-gate clean

bitstream:
	cd $(ROOT) && vivado -mode batch -source fpga/scripts/build.tcl -tclargs $(OUT) 10 1 $(OUT_DIV) $(CLK_HZ) $(BOARD)

program:
	cd $(ROOT) && vivado -mode batch -source fpga/scripts/program.tcl -tclargs $(OUT)/nexys_a7_top.bit

hw-test:
	cd $(ROOT) && python3 fpga/host/attn_host.py --port $(PORT) --n $(N) --seed 1
	cd $(ROOT) && python3 fpga/host/attn_host.py --port $(PORT) --n 64 --seed 7

sweep:
	cd $(ROOT) && python3 fpga/scripts/sweep.py --port $(PORT) --freqs $(FREQS) --n $(N) --board $(BOARD)

hw-gate: bitstream program hw-test sweep
	@echo "FPGA HW GATE: bitstream built, board programmed, golden compare passed on hardware, sweep table at $(ROOT)/build/fpga/sweep.csv"
	@echo "Now: fill docs/phase6_fpga_guide.md section 0 and append the EVIDENCE.md row (Vivado version, utilization, sweep table, measured max)"

clean:
	rm -rf $(ROOT)/build/fpga
