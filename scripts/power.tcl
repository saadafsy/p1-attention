# OpenSTA per-net VCD-annotated power estimate for a yosys-mapped netlist
# (the docs/phase7_physical_guide.md section 7 recipe). Env vars: LIB,
# NETLIST, MODULE, PERIOD_NS, VCD. The VCD scope is the DUT inside gls_tb.
#
# REQUIRES an OpenSTA with read_power_activities (newer than the installed
# 2.0.17). The if/else below makes that failure LOUD and produces NO power
# table: without it, OpenSTA printed the unknown-command error and then
# happily ran report_power with DEFAULT activities, producing plausible-
# looking but uncalibrated numbers (2026-07-16 front-to-back review,
# finding 1). The whole payload lives in the else branch because this
# OpenSTA build continues past errors when sourcing a script and its exit
# ignores status codes, so an early exit-with-error cannot be trusted to
# stop it. Until the tool is upgraded, use scripts/power_proxy.tcl
# (measured-average-activity calibration), which is what the Phase 5
# EVIDENCE numbers come from.
if {[info commands read_power_activities] eq ""} {
    puts "ERROR: this OpenSTA build has no read_power_activities."
    puts "ERROR: no power table produced; use scripts/power_proxy.tcl"
    puts "ERROR: instead (see this script's header comment)."
} else {
    read_liberty $::env(LIB)
    read_verilog $::env(NETLIST)
    link_design $::env(MODULE)

    create_clock -name clk -period $::env(PERIOD_NS) [get_ports clk]

    read_power_activities -scope gls_tb/dut -vcd $::env(VCD)
    report_power
}
exit
