`timescale 1ns / 1ps
// sync2ff: 2-flop synchronizer for asynchronous inputs (button, UART RX).
// RST_VAL: 1'b1 for a UART RX line (idle high), 1'b0 for buttons.
// The reset-button instance ties rst to 0 and relies on Xilinx GSR for its
// initial value; a non-Xilinx or ASIC flow needs a real power-on reset.
module sync2ff #(
    parameter int unsigned WIDTH = 1,
    parameter logic [WIDTH-1:0] RST_VAL = '0
) (
    input  logic             clk,
    input  logic             rst,  // synchronous, active-high
    input  logic [WIDTH-1:0] d,    // asynchronous input
    output logic [WIDTH-1:0] q     // synchronized, 2-cycle latency
);

  // ASYNC_REG on both stages keeps them adjacent and out of retiming/SRLs.
  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] meta;
  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] q_r;

  assign q = q_r;

  always_ff @(posedge clk) begin
    if (rst) begin
      meta <= RST_VAL;
      q_r  <= RST_VAL;
    end else begin
      meta <= d;
      q_r  <= meta;
    end
  end

endmodule
