current_design online_softmax_pipe1
set clk_period 10.0
create_clock -name core_clock -period $clk_period [get_ports clk]
# In attention_top every input comes from a flop and every output goes to
# one, so the block boundary gets 10% of the period on each side.
set_input_delay  [expr {$clk_period * 0.1}] -clock core_clock [delete_from_list [all_inputs] [get_ports clk]]
set_output_delay [expr {$clk_period * 0.1}] -clock core_clock [all_outputs]
