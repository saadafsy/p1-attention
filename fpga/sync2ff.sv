`timescale 1ns / 1ps
// sync2ff: parameterized 2-flip-flop synchronizer (Phase 6 bring-up kit,
// docs/phase6_fpga_guide.md 6.3). Brings a signal that is asynchronous to
// clk (board button, USB-UART RX line) into the clk domain through two
// cascaded flip-flops, the standard metastability filter. Vendor-agnostic:
// the ASYNC_REG attribute is plain attribute syntax that generic tools
// ignore and Vivado uses to keep the pair adjacent.
//
// RST_VAL picks the reset value: 1'b1 for a UART RX line (idle high, so a
// reset must not fabricate a start bit), 1'b0 for buttons.
//
// Reset note (documented exemption to "reset every sequential element",
// spec 6.3): the instance that synchronizes the reset button itself cannot
// be reset by the signal it produces; that one instance ties rst to 1'b0
// and settles to the true button value within 2 clk cycles of
// configuration. Every other instance connects the real rst.
// The exemption leans on the Xilinx target's configuration-time global
// set/reset (GSR): at the end of FPGA configuration every flop loads its
// INIT value (0 here), so the unreset stages start defined on silicon even
// though simulation shows X until the first samples propagate. Auditor
// flag: this is Xilinx-specific; reusing this file on a non-Xilinx target
// or an ASIC flow without a power-on-reset equivalent needs a real POR.
module sync2ff #(
    parameter int unsigned WIDTH = 1,
    parameter logic [WIDTH-1:0] RST_VAL = '0
) (
    input  logic             clk,
    input  logic             rst,  // synchronous, active-high
    input  logic [WIDTH-1:0] d,    // asynchronous input
    output logic [WIDTH-1:0] q     // synchronized, 2-cycle latency
);

  (* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] meta;

  always_ff @(posedge clk) begin
    if (rst) begin
      meta <= RST_VAL;
      q    <= RST_VAL;
    end else begin
      meta <= d;
      q    <= meta;
    end
  end

endmodule
