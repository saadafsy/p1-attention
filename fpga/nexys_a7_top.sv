`timescale 1ns / 1ps
// nexys_a7_top: board top for the Nexys A7-100T (added 2026-09-19,
// target-scores change 2). Wraps attn_uart_top with the one Xilinx
// primitive the clock sweep needs, an MMCME2_BASE that turns the 100 MHz
// oscillator into the design clock at a frequency set by PARAMETERS, so
// fpga/scripts/sweep.tcl can rebuild the bitstream at each target frequency
// without editing any source:
//
//   f_design = 100 MHz * CLKFBOUT_MULT_F / (DIVCLK_DIVIDE * CLKOUT0_DIVIDE_F)
//
// e.g. MULT 10, DIV 1, OUT 10 -> 100 MHz; OUT 20 -> 50 MHz; OUT 8 -> 125 MHz.
// The VCO (100 MHz * MULT / DIVCLK) must stay inside the Artix-7 -1 range
// 600..1200 MHz; MULT 10 gives 1000 MHz. attn_uart_top's CLK_HZ parameter
// is set from the same numbers so the UART baud divider stays correct at
// every sweep point (the host baud never changes).
//
// The design is held in reset until the MMCM reports LOCKED (or the button
// is pressed); led_locked shows the lock. Everything below the MMCM is the
// vendor-neutral kit (attn_uart_top, PIPE_ROM = 1 lanes with block-RAM
// exp tables under XILINX_FPGA, which fpga/scripts/synth.tcl defines).
//
// UNVERIFIED: never synthesized or run (no Vivado, no board where this was
// written). PENDING-HARDWARE until docs/phase6_fpga_guide.md has the log.
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

  // Reset the kit while the MMCM is unlocked; the button still works as
  // the manual reset (attn_uart_top synchronizes it internally).
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
