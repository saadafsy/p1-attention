# OpenSTA switching-activity power estimate for a yosys-mapped netlist,
# driven by the GLS VCDs from tb/gls (Phase 5; recipe per
# docs/phase7_physical_guide.md section 7). Env vars: LIB, NETLIST, MODULE,
# PERIOD_NS, VCD. The VCD scope is the DUT instance inside gls_tb.
# Usage: LIB=... NETLIST=... MODULE=... PERIOD_NS=10 VCD=... \
#          opensta -no_init scripts/power.tcl
read_liberty $::env(LIB)
read_verilog $::env(NETLIST)
link_design $::env(MODULE)

create_clock -name clk -period $::env(PERIOD_NS) [get_ports clk]
set_input_delay 0 -clock clk [all_inputs]
set_output_delay 0 -clock clk [all_outputs]

read_power_activities -scope gls_tb/dut -vcd $::env(VCD)
report_power
exit
