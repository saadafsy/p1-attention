`timescale 1ns / 1ps
// nexys_a7_top: Artix-7 board top for Basys 3 (default) or Nexys A7-100T.
// Wraps attn_uart_top with an MMCME2_BASE so the clock sweep sets the design
// clock by parameter: f = 100 MHz * MULT / (DIVCLK * CLKOUT0_DIVIDE_F).
// VCO must stay in 600..1200 MHz. CLK_HZ must match f so the baud divider holds.
// The kit is held in reset until the MMCM locks.
module nexys_a7_top #(
    parameter real CLKFBOUT_MULT_F  = 10.0,  // VCO = 100 MHz * MULT / DIVCLK
    parameter int  DIVCLK_DIVIDE    = 1,
    parameter real CLKOUT0_DIVIDE_F = 10.0,  // design clock = VCO / this
    parameter int unsigned CLK_HZ   = 100_000_000,  // must equal the formula above
    parameter int unsigned BAUD     = 115_200
) (
    input  logic clk100,
    input  logic rst_btn,
    input  logic uart_rx,
    output logic uart_tx,
    output logic led0,
    output logic led_locked
);

  logic clk_fb, clk_design_unbuf, clk;
  logic locked;

  MMCME2_BASE #(
      .BANDWIDTH        ("OPTIMIZED"),
      .CLKFBOUT_MULT_F  (CLKFBOUT_MULT_F),
      .CLKFBOUT_PHASE   (0.0),
      .CLKIN1_PERIOD    (10.0),
      .CLKOUT0_DIVIDE_F (CLKOUT0_DIVIDE_F),
      .CLKOUT0_DUTY_CYCLE(0.5),
      .CLKOUT0_PHASE    (0.0),
      .CLKOUT1_DIVIDE   (1),
      .CLKOUT2_DIVIDE   (1),
      .CLKOUT3_DIVIDE   (1),
      .CLKOUT4_DIVIDE   (1),
      .CLKOUT5_DIVIDE   (1),
      .CLKOUT6_DIVIDE   (1),
      .CLKOUT4_CASCADE  ("FALSE"),
      .DIVCLK_DIVIDE    (DIVCLK_DIVIDE),
      .REF_JITTER1      (0.010),
      .STARTUP_WAIT     ("FALSE")
  ) u_mmcm (
      .CLKIN1   (clk100),
      .CLKFBIN  (clk_fb),
      .CLKFBOUT (clk_fb),
      .CLKFBOUTB(),
      .CLKOUT0  (clk_design_unbuf),
      .CLKOUT0B (),
      .CLKOUT1  (),
      .CLKOUT1B (),
      .CLKOUT2  (),
      .CLKOUT2B (),
      .CLKOUT3  (),
      .CLKOUT3B (),
      .CLKOUT4  (),
      .CLKOUT5  (),
      .CLKOUT6  (),
      .LOCKED   (locked),
      .PWRDWN   (1'b0),
      .RST      (1'b0)
  );

  BUFG u_bufg (
      .I(clk_design_unbuf),
      .O(clk)
  );

  assign led_locked = locked;

  logic rst_in;
  assign rst_in = rst_btn | ~locked;

  attn_uart_top #(
      .CLK_HZ(CLK_HZ),
      .BAUD  (BAUD)
  ) u_kit (
      .clk    (clk),
      .rst_btn(rst_in),
      .uart_rx(uart_rx),
      .uart_tx(uart_tx),
      .led0   (led0)
  );

endmodule
