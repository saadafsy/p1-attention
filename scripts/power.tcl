# OpenSTA per-net VCD-annotated power estimate for a yosys-mapped netlist
# (the docs/phase7_physical_guide.md section 7 recipe). Env vars: LIB,
# NETLIST, MODULE, PERIOD_NS, VCD. The VCD scope is the DUT inside gls_tb.
#
# REQUIRES an OpenSTA with read_power_activities (newer than the installed
# 2.0.17). Without it, OpenSTA printed the unknown-command error and then
# happily ran report_power with DEFAULT activities, producing plausible-
# looking but uncalibrated numbers (2026-07-16 front-to-back review,
# finding 1). Until the tool is upgraded, use scripts/power_proxy.tcl
# (measured-average-activity calibration), which is what the Phase 5
# EVIDENCE numbers come from.
#
# Exit status (2026-09-18, review finding F010): the unsupported-tool
# branch used to print three ERROR lines and then fall through to a bare
# `exit`, i.e. status 0, so a Make target or CI checking the exit code saw
# success with no power table. It now exits 1, and every tool step is in
# catch so a link/read failure also exits 1.
proc die {msg} {
    puts stderr "ERROR: $msg"
    exit 1
}
if {[info commands read_power_activities] eq ""} {
    die "this OpenSTA build has no read_power_activities; no power table produced; use scripts/power_proxy.tcl instead (see header comment)"
}
foreach v {LIB NETLIST MODULE PERIOD_NS VCD} {
    if {![info exists ::env($v)] || $::env($v) eq ""} { die "env var $v is not set" }
}
if {[catch {
    read_liberty $::env(LIB)
    read_verilog $::env(NETLIST)
    link_design $::env(MODULE)
    create_clock -name clk -period $::env(PERIOD_NS) [get_ports clk]
    read_power_activities -scope gls_tb/dut -vcd $::env(VCD)
    report_power
} msg]} {
    die $msg
}
exit 0
