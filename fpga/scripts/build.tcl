# Vivado batch build of fpga/nexys_a7_top.sv for the Nexys A7-100T.
# Usage (from the repo root):
#   vivado -mode batch -source fpga/scripts/build.tcl -tclargs <out_dir> <mult> <divclk> <out_div> <clk_hz>
# e.g.  ... -tclargs build/fpga/f100 10 1 10 100000000
# Writes <out_dir>/nexys_a7_top.bit, utilization/timing reports, and
# <out_dir>/summary.txt (WNS, WHS, BRAM/DSP/LUT/FF counts, the four
# exp-ROM implementation check). Exit 1 on any failure, including a
# timing-failed bitstream (the sweep records it; a failing-timing bitstream
# is never programmed as "working").
#
# UNVERIFIED: written without Vivado; validate on the first real run.
if {$argc != 5} { puts "usage: build.tcl <out_dir> <mult> <divclk> <out_div> <clk_hz>"; exit 1 }
lassign $argv out_dir mult divclk out_div clk_hz
set root [file normalize [file join [file dirname [info script]] .. ..]]
file mkdir $out_dir

create_project -in_memory -part xc7a100tcsg324-1
set_property target_language Verilog [current_project]
# XILINX_FPGA selects fpga/exp_lut_2p_xilinx.sv (XPM block ROM) in online_softmax.sv
set_property verilog_define {XILINX_FPGA=1} [current_fileset]
set_property include_dirs [list $root] [current_fileset]

read_verilog -sv [list \
  $root/rtl/mac_unit.sv $root/rtl/matmul_tile.sv \
  $root/rtl/exp_lut_2p.sv $root/rtl/online_softmax.sv $root/rtl/attention_top.sv \
  $root/fpga/sync2ff.sv $root/fpga/heartbeat.sv $root/fpga/uart_rx.sv $root/fpga/uart_tx.sv \
  $root/fpga/exp_lut_2p_xilinx.sv $root/fpga/attn_uart_top.sv $root/fpga/nexys_a7_top.sv]
read_mem $root/fpga/exp_lut.mem
read_xdc $root/fpga/nexys_a7_100t.xdc

set generics [list \
  CLKFBOUT_MULT_F=$mult DIVCLK_DIVIDE=$divclk CLKOUT0_DIVIDE_F=$out_div CLK_HZ=$clk_hz]
synth_design -top nexys_a7_top -part xc7a100tcsg324-1 -generic $generics
report_utilization -file $out_dir/util_synth.rpt

# Gate 1: the four lane exp ROMs must be block RAM, not distributed LUT ROM.
set rom_cells [get_cells -hierarchical -filter {NAME =~ *u_rom* && PRIMITIVE_TYPE =~ BMEM.*}]
set n_bram [llength $rom_cells]
puts "exp ROM block-RAM primitives: $n_bram"
if {$n_bram < 4} {
  puts "ERROR: expected >= 4 block-RAM primitives for the four lane exp ROMs, found $n_bram (distributed ROM inferred?)"
  exit 1
}

opt_design
place_design
route_design
report_timing_summary -file $out_dir/timing.rpt
report_utilization -file $out_dir/util_impl.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set util [report_utilization -return_string]

set f [open $out_dir/summary.txt w]
puts $f "part xc7a100tcsg324-1"
puts $f "mmcm mult=$mult divclk=$divclk out_div=$out_div clk_hz=$clk_hz"
puts $f "setup WNS $wns"
puts $f "hold WHS $whs"
puts $f "exp ROM block-RAM primitives $n_bram"
puts $f $util
close $f
puts "setup WNS $wns  hold WHS $whs"

if {$wns < 0 || $whs < 0} {
  puts "ERROR: timing not met at clk_hz=$clk_hz (WNS $wns WHS $whs); no bitstream written"
  exit 1
}
write_bitstream -force $out_dir/nexys_a7_top.bit
puts "bitstream: $out_dir/nexys_a7_top.bit"
exit 0
