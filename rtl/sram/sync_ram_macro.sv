`timescale 1ns / 1ps
// sync_ram on SRAM macros: replaces rtl/sync_ram.sv in the sky130 macro build
// (pd/attention_top, tb/attention_top_sram), so attention_top is unchanged.
// verilator lint_off DECLFILENAME
// verilog_lint: waive module-filename
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

  sync_ram_sky130 #(
      .AW(AW),
      .DW(DW)
  ) u_ram (
      .clk  (clk),
      .rst  (rst),
      .we   (we),
      .be   (be),
      .waddr(waddr),
      .wdata(wdata),
      .raddr(raddr),
      .rdata(rdata)
  );

endmodule
