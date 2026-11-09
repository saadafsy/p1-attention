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

# In the macro LEFs two columns of pads are listed under both vdd and gnd
# (64x256: x = 163.77 and 876.35; 128x256: x = 214.22 and 926.80, macro
# coordinates). A via there would short VDD to VSS, so the straps, at
# x = offset - halo + 13.57 k (VDD and VSS alternating), miss both columns.
foreach {cell off} {sky130_sram_1rw1r_64x256_8 12.5 sky130_sram_1rw1r_128x256_8 8.8} {
  define_pdn_grid -name $cell -voltage_domains {CORE} -macro -cells $cell \
    -halo {2.0 2.0 2.0 2.0} -grid_over_boundary
  add_pdn_stripe -grid $cell -layer {met4} -width {1.600} -pitch {27.140} -offset $off
  add_pdn_connect -grid $cell -layers {met3 met4}
  add_pdn_connect -grid $cell -layers {met4 met5}
}
