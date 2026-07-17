# Phase 5 power proxy: OpenSTA report_power with the average switching
# activity MEASURED from the matching GLS VCD (scripts/toggle_count.py).
# This opensta build (2.0.17) predates read_power_activities, so per-net VCD
# annotation is not possible; instead the measured average activity
# (toggles / net / cycle) is applied globally with set_power_activity. That
# makes this a TOOL ESTIMATE calibrated by measured average activity, not a
# per-net activity simulation; say so wherever the numbers are quoted.
# Env vars: LIB, NETLIST, MODULE, PERIOD_NS (use the config's MET period),
# ACTIVITY (measured avg toggles/net/cycle).
read_liberty $::env(LIB)
read_verilog $::env(NETLIST)
link_design $::env(MODULE)

create_clock -name clk -period $::env(PERIOD_NS) [get_ports clk]

set_power_activity -global -activity $::env(ACTIVITY) -duty 0.5
report_power
exit
