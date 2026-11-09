# sky130hd platform grid (platforms/sky130hd/pdn.tcl) plus a grid for the
# OpenRAM macros. Their supply pins (vdd, gnd) are met3 pads spread over the
# macro, so met4 straps run over each macro, drop vias onto the pads and
# connect up to the met5 core straps.
add_global_connection -net {VDD} -inst_pattern {.*} -pin_pattern {^vdd$} -power
add_global_connection -net {VSS} -inst_pattern {.*} -pin_pattern {^gnd$} -ground
global_connect

set_voltage_domain -name {CORE} -power {VDD} -ground {VSS}

define_pdn_grid -name {grid} -voltage_domains {CORE} -pins {met5}
add_pdn_stripe -grid {grid} -layer {met1} -width {0.48} -pitch {5.44} -offset {0} -followpins
add_pdn_stripe -grid {grid} -layer {met4} -width {1.600} -pitch {27.140} -offset {13.570}
add_pdn_stripe -grid {grid} -layer {met5} -width {1.600} -pitch {27.200} -offset {13.600}
add_pdn_connect -grid {grid} -layers {met1 met4}
add_pdn_connect -grid {grid} -layers {met4 met5}

# The macro grids stay inside the macros (no -grid_over_boundary, which put
# macro straps next to core via stacks outside the macro edge). The
# vdd/gnd pads that overlap each other are OBS in the patched LEFs
# (prepare.sh, patch_sram_lef.py).
foreach cell {sky130_sram_1rw1r_64x256_8 sky130_sram_1rw1r_128x256_8} {
  define_pdn_grid -name $cell -voltage_domains {CORE} -macro -cells $cell \
    -halo {2.0 2.0 2.0 2.0}
  add_pdn_stripe -grid $cell -layer {met4} -width {1.600} -pitch {27.140} -offset {13.570}
  add_pdn_connect -grid $cell -layers {met3 met4}
  add_pdn_connect -grid $cell -layers {met4 met5}
}
