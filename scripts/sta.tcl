# OpenSTA script for Phase 4 timing checks on a yosys-mapped netlist.
# Driven by env vars: LIB (liberty path), NETLIST, MODULE, PERIOD_NS.
# Usage: LIB=... NETLIST=... MODULE=... PERIOD_NS=10 opensta -no_init scripts/sta.tcl
read_liberty $::env(LIB)
read_verilog $::env(NETLIST)
link_design $::env(MODULE)

create_clock -name clk -period $::env(PERIOD_NS) [get_ports clk]
# Zero-margin I/O for a block-level look; Phase 4 tightens with real budgets.
set_input_delay 0 -clock clk [all_inputs]
set_output_delay 0 -clock clk [all_outputs]

# This OpenSTA build (2.0.17, 2019) predates 'report_worst_slack -max' syntax;
# the worst setup path and its slack come from report_checks instead, and the
# min/hold side from -path_delay min.
report_checks -path_delay max -digits 3
puts "---HOLD-CHECK---"
report_checks -path_delay min -digits 3
exit
