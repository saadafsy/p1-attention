`timescale 1ns / 1ps
// Basys 3 top at a 75 MHz design clock (MMCM: 100 MHz * 9 / 12), for the
// openXC7 build (yosys cannot set real parameters from the command line).
module top_75mhz (
    input  logic clk100,
    input  logic rst_btn,
    input  logic uart_rx,
    output logic uart_tx,
    output logic led0,
    output logic led_locked
);
  nexys_a7_top #(
      .CLKFBOUT_MULT_F (9.0),
      .DIVCLK_DIVIDE   (1),
      .CLKOUT0_DIVIDE_F(12.0),
      .CLK_HZ          (75_000_000)
  ) u_top (
      .clk100    (clk100),
      .rst_btn   (rst_btn),
      .uart_rx   (uart_rx),
      .uart_tx   (uart_tx),
      .led0      (led0),
      .led_locked(led_locked)
  );
endmodule
