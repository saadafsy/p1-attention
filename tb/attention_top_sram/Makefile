# tb/attention_top's cocotb tests on attention_top with the four memories as
# OpenRAM macro models (rtl/sram/, tb/sram_models/), Verilator --timing.
# RAM=rtl runs the same tests on rtl/sync_ram.sv for a side-by-side count.
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)
R := $(PWD)/../../rtl
M := $(PWD)/../sram_models
RAM ?= sram
ifeq ($(RAM),rtl)
RAM_SOURCES = $(R)/sync_ram.sv
else
RAM_SOURCES = $(M)/models.vlt $(R)/sram/sync_ram_macro.sv $(R)/sram/sync_ram_sky130.sv \
              $(M)/sky130_sram_sim.sv $(M)/sky130_sram_1rw1r_64x256_8_model.v \
              $(M)/sky130_sram_1rw1r_128x256_8_model.v
endif
VERILOG_SOURCES = $(R)/mac_unit.sv $(R)/matmul_tile.sv $(R)/exp_lut_1p.sv \
                  $(RAM_SOURCES) $(R)/online_softmax.sv $(R)/attention_top.sv

COCOTB_TOPLEVEL = attention_top
COCOTB_TEST_MODULES = test_attention_top_sram

PIPE_ROM ?= 1
SIM_BUILD := sim_build_$(RAM)_p$(PIPE_ROM)
COCOTB_RESULTS_FILE := results_$(RAM)_p$(PIPE_ROM).xml
export SRAM_TB_TAG := $(RAM)_p$(PIPE_ROM)
EXTRA_ARGS += -GPIPE_ROM=$(PIPE_ROM) +incdir+$(PWD)/../.. --timing --timescale 1ns/1ps

SEED ?= 1
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
