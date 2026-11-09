# OpenSTA per-net VCD-annotated power for a yosys netlist. Env: LIB NETLIST MODULE PERIOD_NS VCD.
# Needs read_power_activities (absent in OpenSTA 2.0.17, which would silently use default
# activities); otherwise exits 1, use scripts/power_proxy.tcl. Any failed step exits 1.
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
