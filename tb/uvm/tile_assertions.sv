`timescale 1ns / 1ps
// SVA for the matmul_tile UVM environment, bound to the RTL (not edited
// into it): the mac_unit clr/en contract (docs/uarch.md 8.1 table), the
// D<=511 no-overflow guarantee (uarch.md 3.2) checked as a mathematical
// bound on the NEXT value before the register truncates, and the tile's
// timing contract (post-edge accumulator state is a function of the
// previous cycle's control/operands only: no extra latency, no valid pulse
// to wait for). Concurrent assertions with |=>, the form the RTL's own
// `ifdef FORMAL blocks avoid for SymbiYosys; here the simulator is a
// full-SVA one (xsim), so the richer form is used and this file is NOT
// read by the sby flows.

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

  // Control contract, one row each (uarch.md 8.1).
  a_rst:      assert property (@(posedge clk) rst |=> acc == 24'sd0);
  a_clr_only: assert property (@(posedge clk) disable iff (rst) (clr && !en) |=> acc == 24'sd0);
  a_load:     assert property (@(posedge clk) disable iff (rst) (clr && en)
                               |=> acc == 24'($past(a) * $past(b)));
  a_accum:    assert property (@(posedge clk) disable iff (rst) (!clr && en)
                               |=> acc == 24'($past(acc) + $past(a) * $past(b)));
  a_hold:     assert property (@(posedge clk) disable iff (rst) (!clr && !en) |=> acc == $past(acc));

  // No overflow: the mathematical next value must fit signed 24 bits. This
  // is the 3.2 bound stated as a runtime check on the value the register is
  // about to truncate, not a tautology on the register's own range. A
  // stimulus that accumulates past D = 511 terms of +-2^14 legitimately
  // trips it: that is out of spec by design (the cocotb width-edge test
  // does it on purpose; the UVM sequences stay in spec).
  a_no_overflow: assert property (@(posedge clk) disable iff (rst)
                                  next_exact >= -(1 << 23) && next_exact < (1 << 23));

  // Timing contract: the registered acc only ever moves on a clock edge as
  // a function of that edge's inputs (covered by the five rows above);
  // additionally, with en low and clr low for a cycle the value is stable,
  // i.e. there is no hidden pipeline still draining into acc.
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
  // Whole-bus versions of the reset/clear/hold rows (all 16 PEs share
  // rst/clr/en, uarch.md 8.1).
  a_rst:      assert property (@(posedge clk) rst |=> acc_flat == 384'd0);
  a_clr_only: assert property (@(posedge clk) disable iff (rst) (clr && !en) |=> acc_flat == 384'd0);
  a_hold:     assert property (@(posedge clk) disable iff (rst) (!clr && !en) |=> acc_flat == $past(acc_flat));
endmodule


// Bind into every mac_unit and the tile (tb_top compiles this file after
// the RTL). Port names match rtl/mac_unit.sv and rtl/matmul_tile.sv.
bind mac_unit    mac_contract_sva  u_mac_sva  (.clk(clk), .rst(rst), .en(en), .clr(clr), .a(a), .b(b), .acc(acc));
bind matmul_tile tile_contract_sva u_tile_sva (.clk(clk), .rst(rst), .en(en), .clr(clr), .acc_flat(acc_flat));
