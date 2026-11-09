# Power proxy: OpenSTA report_power with the GLS-measured average activity applied globally
# (OpenSTA 2.0.17 has no per-net VCD annotation), so it is a tool estimate, not per-net.
# Env: LIB NETLIST MODULE PERIOD_NS ACTIVITY (avg toggles/net/cycle). Any failed step exits 1.
proc die {msg} {
    puts stderr "ERROR: $msg"
    exit 1
}
foreach v {LIB NETLIST MODULE PERIOD_NS ACTIVITY} {
    if {![info exists ::env($v)] || $::env($v) eq ""} { die "env var $v is not set" }
}
if {[catch {
    read_liberty $::env(LIB)
    read_verilog $::env(NETLIST)
    link_design $::env(MODULE)
    create_clock -name clk -period $::env(PERIOD_NS) [get_ports clk]
    set_power_activity -global -activity $::env(ACTIVITY) -duty 0.5
    report_power
} msg]} {
    die $msg
}
exit 0
