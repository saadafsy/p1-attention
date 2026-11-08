`timescale 1ns / 1ps
// sync_ram: one write port with byte enables, one registered read port.
// Written in the standard byte-write-enable inference template, so Vivado
// and yosys map it to block RAM (RAMB18/RAMB36) on an FPGA. In an ASIC flow
// it stands for an SRAM macro; scripts/sync_ram_sta_stub.sv replaces it for
// top-level STA (see docs/uarch.md 8.3, make sta-top).
//
// Read: rdata = mem[raddr] one cycle later (old data on a same-address
// write, like a BRAM in READ_FIRST mode). Contents are not reset (a reset
// on RAM contents blocks BRAM inference); only the output register is.
module sync_ram #(
    parameter int AW = 8,  // address bits
    parameter int DW = 32,  // data bits, a multiple of 8
    localparam int NB = DW / 8
) (
    input  logic          clk,
    input  logic          rst,    // synchronous, clears the read register
    input  logic          we,
    input  logic [NB-1:0] be,     // byte enables for the write
    input  logic [AW-1:0] waddr,
    input  logic [DW-1:0] wdata,
    input  logic [AW-1:0] raddr,
    output logic [DW-1:0] rdata
);

  logic [DW-1:0] mem[2**AW];

  always_ff @(posedge clk) begin
    if (we) begin
      for (int b = 0; b < NB; b++) begin
        if (be[b]) mem[waddr][8*b+:8] <= wdata[8*b+:8];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) rdata <= '0;
    else rdata <= mem[raddr];
  end

endmodule
