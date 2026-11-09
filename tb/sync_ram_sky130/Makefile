# sync_ram vs sync_ram_sky130 on the OpenRAM models (Verilator --timing).
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

PWD := $(shell pwd)
M := $(PWD)/../sram_models
VERILOG_SOURCES = $(M)/models.vlt \
                  $(PWD)/../../rtl/sync_ram.sv \
                  $(PWD)/../../rtl/sram/sync_ram_sky130.sv \
                  $(M)/sky130_sram_sim.sv \
                  $(M)/sky130_sram_1rw1r_64x256_8_model.v \
                  $(M)/sky130_sram_1rw1r_128x256_8_model.v \
                  $(PWD)/tb_sync_ram_pair.sv

COCOTB_TOPLEVEL = tb_sync_ram_pair
COCOTB_TEST_MODULES = test_sync_ram_sky130
EXTRA_ARGS += --timing --timescale 1ns/1ps

SEED ?= 1
export COCOTB_RANDOM_SEED = $(SEED)

include $(shell cocotb-config --makefiles)/Makefile.sim
