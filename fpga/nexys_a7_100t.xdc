## Nexys A7-100T (xc7a100tcsg324-1) constraints for fpga/nexys_a7_top.sv.
## Pins from Digilent's Nexys-A7-100T-Master.xdc; board names in comments.

## 100 MHz system clock (board: CLK100MHZ, pin E3)
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports clk100]
create_clock -name sys_clk -period 10.000 [get_ports clk100]

## Reset: center button (board: BTNC, pin N17, active high when pressed)
set_property -dict { PACKAGE_PIN N17 IOSTANDARD LVCMOS33 } [get_ports rst_btn]

## USB-UART bridge (board: UART_TXD_IN C4 host -> FPGA, UART_RXD_OUT D4 FPGA -> host)
set_property -dict { PACKAGE_PIN C4  IOSTANDARD LVCMOS33 } [get_ports uart_rx]
set_property -dict { PACKAGE_PIN D4  IOSTANDARD LVCMOS33 } [get_ports uart_tx]

## Heartbeat LED (board: LED0, pin H17) and MMCM-locked LED (LED1, pin K15)
set_property -dict { PACKAGE_PIN H17 IOSTANDARD LVCMOS33 } [get_ports led0]
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports led_locked]

## Configuration
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## Async inputs are 2-FF synchronized inside the design (fpga/sync2ff.sv)
set_false_path -from [get_ports rst_btn]
set_false_path -from [get_ports uart_rx]

## The MMCM output clock is derived from sys_clk automatically.
