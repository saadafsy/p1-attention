current_design attention_top
# 12.5 ns: the OpenRAM macros drive read data from the falling clock edge, so
# paths from the macros get half a cycle. After global route the setup slack
# was -1.32 ns at 10 ns and -0.50 ns at 11.5 ns (runs of 2026-11-09).
set clk_period 12.5
create_clock -name core_clock -period $clk_period [get_ports clk]
# Block boundary: 10% of the period on each side, as for the other blocks.
set_input_delay  [expr {$clk_period * 0.1}] -clock core_clock [delete_from_list [all_inputs] [get_ports clk]]
set_output_delay [expr {$clk_period * 0.1}] -clock core_clock [all_outputs]
