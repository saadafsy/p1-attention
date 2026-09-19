## Basys 3 constraints for fpga/nexys_a7_top.sv (the board top is board-
## agnostic: 100 MHz in, MMCM, button, UART, two LEDs). Pin names from
## Digilent's Basys-3-Master.xdc (github.com/Digilent/digilent-xdc).
## Part: xc7a35tcpg236-1. UNVERIFIED: no bitstream has been built from this
## file yet. Added 2026-09-19.

## 100 MHz system clock (board: clk, pin W5)
set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 } [get_ports clk100]
create_clock -name sys_clk -period 10.000 [get_ports clk100]

## Reset: center button (board: btnC, pin U18, active high when pressed)
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports rst_btn]

## USB-UART bridge (board: RsRx B18 is host -> FPGA, RsTx A18 is FPGA -> host)
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 } [get_ports uart_rx]
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports uart_tx]

## Heartbeat LED (board: led[0], pin U16) and MMCM-locked LED (led[1], pin E19)
set_property -dict { PACKAGE_PIN U16 IOSTANDARD LVCMOS33 } [get_ports led0]
set_property -dict { PACKAGE_PIN E19 IOSTANDARD LVCMOS33 } [get_ports led_locked]

## Configuration
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## Async inputs are 2-FF synchronized inside the design (fpga/sync2ff.sv)
set_false_path -from [get_ports rst_btn]
set_false_path -from [get_ports uart_rx]
