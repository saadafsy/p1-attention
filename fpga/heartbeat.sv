`timescale 1ns / 1ps
// heartbeat: toggles led every CLK_HZ/2 cycles (1 Hz blink). A dark LED on
// the board means clock or reset is broken.
module heartbeat #(
    parameter int unsigned CLK_HZ = 100_000_000
) (
    input  logic clk,
    input  logic rst,  // synchronous, active-high
    output logic led
);

  localparam int unsigned HalfPeriod = CLK_HZ / 2;
  localparam int unsigned CntW = $clog2(HalfPeriod);

  logic [CntW-1:0] cnt;

  always_ff @(posedge clk) begin
    if (rst) begin
      cnt <= '0;
      led <= 1'b0;
    end else if (cnt == CntW'(HalfPeriod - 1)) begin
      cnt <= '0;
      led <= ~led;
    end else begin
      cnt <= cnt + 1'b1;
    end
  end

endmodule
