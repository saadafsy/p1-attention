export DESIGN_NICKNAME = attention_top
export DESIGN_NAME     = attention_top
export PLATFORM        = sky130hd

# rtl/sram/sync_ram_macro.sv replaces rtl/sync_ram.sv: the four memories are
# OpenRAM macros (Q, K: 64x256; V, out: 128x256).
export VERILOG_FILES = /work/rtl/mac_unit.sv /work/rtl/matmul_tile.sv \
                       /work/rtl/exp_lut_1p.sv /work/rtl/online_softmax.sv \
                       /work/rtl/sram/sync_ram_sky130.sv /work/rtl/sram/sync_ram_macro.sv \
                       /work/rtl/attention_top.sv
export VERILOG_INCLUDE_DIRS = /work
export VERILOG_TOP_PARAMS = PIPE_ROM 1
export SDC_FILE = /work/pd/attention_top/constraint.sdc

SRAM_DIR = /OpenROAD-flow-scripts/flow/platforms/sky130ram
SRAM_64  = $(SRAM_DIR)/sky130_sram_1rw1r_64x256_8/sky130_sram_1rw1r_64x256_8
SRAM_128 = $(SRAM_DIR)/sky130_sram_1rw1r_128x256_8/sky130_sram_1rw1r_128x256_8
# LEFs with the overlapping vdd/gnd pads moved to OBS (prepare.sh,
# patch_sram_lef.py); the GDS and liberty are the originals.
export ADDITIONAL_LEFS = /work/build/lef/sky130_sram_1rw1r_64x256_8.lef \
                         /work/build/lef/sky130_sram_1rw1r_128x256_8.lef
export ADDITIONAL_LIBS = $(SRAM_64)_TT_1p8V_25C.lib $(SRAM_128)_TT_1p8V_25C.lib
export ADDITIONAL_GDS  = $(SRAM_64).gds $(SRAM_128).gds

# Macros 2.28 mm2, standard cells about 0.87 mm2 after synthesis.
export DIE_AREA  = 0 0 2500 2300
export CORE_AREA = 10 10 2490 2290
export MACRO_PLACEMENT_TCL = /work/pd/attention_top/macro_placement.tcl
export MACRO_PLACE_HALO    = 10 10
export PDN_TCL             = /work/pd/attention_top/pdn.tcl
export PLACE_DENSITY = 0.45
# Repair to 80% of the slew/cap limits so the post-route values stay inside them.
export SLEW_MARGIN = 20
export CAP_MARGIN  = 20
