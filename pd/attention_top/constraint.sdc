current_design attention_top
set clk_period 10.0
create_clock -name core_clock -period $clk_period [get_ports clk]
# Block boundary: 10% of the period on each side, as for the other blocks.
set_input_delay  [expr {$clk_period * 0.1}] -clock core_clock [delete_from_list [all_inputs] [get_ports clk]]
set_output_delay [expr {$clk_period * 0.1}] -clock core_clock [all_outputs]
