`timescale 1ns / 1ps
// sync_ram (reference) and sync_ram_sky130 side by side on the same inputs,
// for both shapes attention_top uses: Q/K (AW=8, DW=32), V/out (AW=6, DW=128).
module tb_sync_ram_pair (
    input  logic         clk,
    input  logic         rst,
    input  logic         we_a,
    input  logic [  3:0] be_a,
    input  logic [  7:0] waddr_a,
    input  logic [ 31:0] wdata_a,
    input  logic [  7:0] raddr_a,
    output logic [ 31:0] ref_a,
    output logic [ 31:0] mac_a,
    input  logic         we_b,
    input  logic [ 15:0] be_b,
    input  logic [  5:0] waddr_b,
    input  logic [127:0] wdata_b,
    input  logic [  5:0] raddr_b,
    output logic [127:0] ref_b,
    output logic [127:0] mac_b
);

  sync_ram #(.AW(8), .DW(32)) u_ref_a (
      .clk(clk), .rst(rst), .we(we_a), .be(be_a), .waddr(waddr_a),
      .wdata(wdata_a), .raddr(raddr_a), .rdata(ref_a)
  );
  sync_ram_sky130 #(.AW(8), .DW(32)) u_mac_a (
      .clk(clk), .rst(rst), .we(we_a), .be(be_a), .waddr(waddr_a),
      .wdata(wdata_a), .raddr(raddr_a), .rdata(mac_a)
  );
  sync_ram #(.AW(6), .DW(128)) u_ref_b (
      .clk(clk), .rst(rst), .we(we_b), .be(be_b), .waddr(waddr_b),
      .wdata(wdata_b), .raddr(raddr_b), .rdata(ref_b)
  );
  sync_ram_sky130 #(.AW(6), .DW(128)) u_mac_b (
      .clk(clk), .rst(rst), .we(we_b), .be(be_b), .waddr(waddr_b),
      .wdata(wdata_b), .raddr(raddr_b), .rdata(mac_b)
  );

endmodule
