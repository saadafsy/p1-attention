`timescale 1ns / 1ps
// tile_if: the DUT-facing interface of the matmul_tile UVM environment.
// One clocking block for the driver (drive after the edge), one for the
// monitor (sample before the edge), so stimulus and observation never race
// the DUT's NBA updates. acc_flat in mon_cb is the value visible DURING
// the cycle, i.e. the result of the previous edge, which is what the golden
// vector file's "acc after the edge" column describes for the previous
// stimulus line.
interface tile_if (
    input logic clk
);
  logic         rst;
  logic         en;
  logic         clr;
  logic [ 31:0] q_flat;
  logic [ 31:0] k_flat;
  logic [383:0] acc_flat;

  // Edge counter: the value read through a clocking block at posedge N is
  // the count BEFORE edge N (N-1 edges seen). Driver and monitor stamp every
  // transaction with the edge it applies to, so the scoreboard pairs driven
  // and observed edges by number instead of by arrival order (robust to the
  // idle edges before the first sequence item).
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
