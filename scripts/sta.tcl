# OpenSTA setup/hold checks on a yosys-mapped netlist.
# Usage: LIB=... NETLIST=... MODULE=... PERIOD_NS=10 opensta -no_init scripts/sta.tcl
# OpenSTA continues past failed commands, so every step is in catch and exits 1 on failure.
proc die {msg} {
    puts stderr "ERROR: $msg"
    exit 1
}
foreach v {LIB NETLIST MODULE PERIOD_NS} {
    if {![info exists ::env($v)] || $::env($v) eq ""} { die "env var $v is not set" }
}
if {![file exists $::env(LIB)]}     { die "LIB file not found: $::env(LIB)" }
if {![file exists $::env(NETLIST)]} { die "NETLIST file not found: $::env(NETLIST)" }

if {[catch {
    read_liberty $::env(LIB)
    read_verilog $::env(NETLIST)
    link_design $::env(MODULE)

    create_clock -name clk -period $::env(PERIOD_NS) [get_ports clk]
    # Zero-margin I/O: block-level check.
    set_input_delay 0 -clock clk [all_inputs]
    set_output_delay 0 -clock clk [all_outputs]

    # OpenSTA 2.0.17 lacks 'report_worst_slack -max', so slack comes from report_checks.
    report_checks -path_delay max -digits 3
    puts "---HOLD-CHECK---"
    report_checks -path_delay min -digits 3
} msg]} {
    die $msg
}
exit 0
