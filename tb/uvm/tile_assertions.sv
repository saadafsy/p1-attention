`timescale 1ns / 1ps
// Concurrent SVA bound into the RTL for the UVM environment (not read by
// sby): the mac_unit clr/en contract (uarch 8.1), the no-overflow bound on
// the untruncated next value (uarch 3.2), and no hidden latency.

module mac_contract_sva (
    input logic               clk,
    input logic               rst,
    input logic               en,
    input logic               clr,
    input logic signed [ 7:0] a,
    input logic signed [ 7:0] b,
    input logic signed [23:0] acc
);
  // Exact next value, computed wide enough to see an overflow.
  logic signed [31:0] next_exact;
  always_comb begin
    if (rst)          next_exact = 0;
    else if (clr)     next_exact = en ? 32'(a) * 32'(b) : 0;
    else if (en)      next_exact = 32'(acc) + 32'(a) * 32'(b);
    else              next_exact = 32'(acc);
  end

  // Control contract, one row each.
  a_rst:      assert property (@(posedge clk) rst |=> acc == 24'sd0);
  a_clr_only: assert property (@(posedge clk) disable iff (rst) (clr && !en) |=> acc == 24'sd0);
  a_load:     assert property (@(posedge clk) disable iff (rst) (clr && en)
                               |=> acc == 24'($past(a) * $past(b)));
  a_accum:    assert property (@(posedge clk) disable iff (rst) (!clr && en)
                               |=> acc == 24'($past(acc) + $past(a) * $past(b)));
  a_hold:     assert property (@(posedge clk) disable iff (rst) (!clr && !en) |=> acc == $past(acc));

  // The exact next value must fit s24. Accumulating past D = 511 terms of
  // +-2^14 is out of spec and trips it; the UVM sequences stay in spec.
  a_no_overflow: assert property (@(posedge clk) disable iff (rst)
                                  next_exact >= -(1 << 23) && next_exact < (1 << 23));

  // No hidden pipeline: idle control keeps acc stable.
  a_no_hidden_latency: assert property (@(posedge clk) disable iff (rst)
                                        (!en && !clr)[*2] |-> $stable(acc));
endmodule


module tile_contract_sva (
    input logic         clk,
    input logic         rst,
    input logic         en,
    input logic         clr,
    input logic [383:0] acc_flat
);
  // Whole-bus reset/clear/hold (all 16 PEs share rst/clr/en).
  a_rst:      assert property (@(posedge clk) rst |=> acc_flat == 384'd0);
  a_clr_only: assert property (@(posedge clk) disable iff (rst) (clr && !en) |=> acc_flat == 384'd0);
  a_hold:     assert property (@(posedge clk) disable iff (rst) (!clr && !en) |=> acc_flat == $past(acc_flat));
endmodule


// Bind into every mac_unit and the tile (compiled after the RTL).
bind mac_unit    mac_contract_sva  u_mac_sva  (.clk(clk), .rst(rst), .en(en), .clr(clr), .a(a), .b(b), .acc(acc));
bind matmul_tile tile_contract_sva u_tile_sva (.clk(clk), .rst(rst), .en(en), .clr(clr), .acc_flat(acc_flat));
