`timescale 1ns / 1ps
// tile_if: matmul_tile UVM interface. drv_cb drives after the edge, mon_cb
// samples before it, so neither races the DUT. mon_cb.acc_flat is the result
// of the previous edge.
interface tile_if (
    input logic clk
);
  logic         rst;
  logic         en;
  logic         clr;
  logic [ 31:0] q_flat;
  logic [ 31:0] k_flat;
  logic [383:0] acc_flat;

  // Edge counter (reads N-1 at posedge N). Transactions are stamped with
  // their edge so the scoreboard pairs by edge number, not arrival order.
  int unsigned cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output rst, en, clr, q_flat, k_flat;
    input acc_flat, cycle;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst, en, clr, q_flat, k_flat, acc_flat, cycle;
  endclocking

  modport DRV(clocking drv_cb);
  modport MON(clocking mon_cb);
endinterface
