`timescale 1ns / 1ps
// STA-only stand-in for rtl/sync_ram.sv (make sta-top). In an ASIC the four
// attention_top memories would be SRAM macros, not 32k standard-cell flip
// flops; flattening them into flops is what made the old top-level STA
// meaningless (a control flop driving thousands of flop-RAM selects). This
// stub keeps the macro's pin boundary: every input is captured into a flop
// (setup is checked on all write/read address, data and enable pins) and
// rdata comes out of a flop (the macro's registered read). What it does NOT
// model is the macro's own clock-to-q and setup, because no sky130 SRAM
// liberty is part of this flow; the summary labels the result accordingly.
// The internal XOR only keeps the captured inputs alive through synthesis.
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
