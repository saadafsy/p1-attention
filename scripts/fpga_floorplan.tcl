# Dump the placement of a routed Vivado checkpoint for scripts/fpga_floorplan.py.
#   vivado -mode batch -nojournal -source scripts/fpga_floorplan.tcl -tclargs <routed.dcp> <out.csv>
# Rows: S,<site>,<site type>,<x>,<y> for every slice / block RAM / DSP site on the part,
#       C,<site>,<cell path>        for every placed leaf cell.
lassign $argv dcp out
open_checkpoint $dcp
set f [open $out w]
foreach s [get_sites -filter {SITE_TYPE =~ SLICE* || SITE_TYPE =~ RAMB* || SITE_TYPE =~ DSP48*}] {
  puts $f "S,[get_property NAME $s],[get_property SITE_TYPE $s],[get_property RPM_X $s],[get_property RPM_Y $s]"
}
foreach c [get_cells -hier -filter {IS_PRIMITIVE && LOC != ""}] {
  puts $f "C,[get_property LOC $c],$c"
}
close $f
exit 0
