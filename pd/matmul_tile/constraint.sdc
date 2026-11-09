current_design matmul_tile
set clk_period 10.0
create_clock -name core_clock -period $clk_period [get_ports clk]
# Inputs come from flops in attention_top and acc_flat is registered.
set_input_delay  [expr {$clk_period * 0.1}] -clock core_clock [delete_from_list [all_inputs] [get_ports clk]]
set_output_delay [expr {$clk_period * 0.1}] -clock core_clock [all_outputs]
