`timescale 1ns / 1ps
// STA-only stand-in for rtl/sync_ram.sv (make sta-top): models an SRAM macro's pin
// boundary (all inputs captured in flops, registered rdata) instead of 32k flop-RAM cells.
// Macro clock-to-q and setup are not modeled (no sky130 SRAM liberty in this flow).
// The XOR only keeps the captured inputs alive through synthesis.
module sync_ram #(
    parameter int AW = 8,
    parameter int DW = 32,
    localparam int NB = DW / 8
) (
    input  logic          clk,
    input  logic          rst,
    input  logic          we,
    input  logic [NB-1:0] be,
    input  logic [AW-1:0] waddr,
    input  logic [DW-1:0] wdata,
    input  logic [AW-1:0] raddr,
    output logic [DW-1:0] rdata
);

  (* keep *) logic          we_q;
  (* keep *) logic [NB-1:0] be_q;
  (* keep *) logic [AW-1:0] waddr_q;
  (* keep *) logic [DW-1:0] wdata_q;
  (* keep *) logic [AW-1:0] raddr_q;

  always_ff @(posedge clk) begin
    we_q    <= we;
    be_q    <= be;
    waddr_q <= waddr;
    wdata_q <= wdata;
    raddr_q <= raddr;
    if (rst) rdata <= '0;
    else rdata <= wdata_q ^ {DW{^{we_q, be_q, waddr_q, raddr_q}}};
  end

endmodule
