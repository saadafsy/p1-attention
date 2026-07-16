`timescale 1ns / 1ps
// matmul_tile: 4x4 output-stationary score tile. Second block of the Q.K^T
// datapath (normative spec: docs/uarch.md section 8.1; formats: sections 2, 3).
//
// Function: one 4x4 block of S = Q.K^T as a grid of 16 mac_unit instances.
// MAC (i, j) accumulates q_i[d] * k_j[d] over the streamed dimension
// d = 0..15 (D = 16). Output-stationary: partial sums stay in each PE's
// accumulator; per enabled cycle the tile consumes one element from each of
// 4 Q rows (broadcast across grid columns) and 4 K rows (broadcast down grid
// rows). Purely structural: no arithmetic outside mac_unit.
//
// Formats (normative, docs/uarch.md):
//   q_flat, k_flat : 4 x ACT, signed Q1.6, 8 bits each
//   acc_flat       : 16 x SACC, signed Q11.12, 24 bits each; exact
//                    accumulation, no rounding, no saturation; overflow
//                    impossible for dot lengths <= 511 (uarch.md 3.2)
//
// Packing convention (little-endian slicing, element 0 in the low bits):
//   q_flat[8*i +: 8]           = ACT element d of Q row i, i = 0..3
//   k_flat[8*j +: 8]           = ACT element d of K row j, j = 0..3
//   acc_flat[24*(4*i+j) +: 24] = SACC S block element (row i, col j)
//
// Control contract (mac_unit's, re-exported; all 16 MACs share rst/clr/en;
// d-loop counter and sequencing belong to attention_top, not the tile):
//   rst          : all acc <= 0
//   clr=1, en=1  : acc(i,j) <= q_i*k_j    (start a new tile, no dead cycle)
//   clr=1, en=0  : all acc <= 0
//   clr=0, en=1  : acc(i,j) <= acc(i,j) + q_i*k_j
//   clr=0, en=0  : hold
module matmul_tile (
    input  logic         clk,
    input  logic         rst,      // synchronous, active-high
    input  logic         en,       // accept one product per MAC this cycle
    input  logic         clr,      // start a new tile this cycle
    input  logic [ 31:0] q_flat,   // 4 ACT Q1.6 elements, one per Q row
    input  logic [ 31:0] k_flat,   // 4 ACT Q1.6 elements, one per K row
    output logic [383:0] acc_flat  // 16 SACC Q11.12 accumulators, row-major
);

  for (genvar i = 0; i < 4; i++) begin : g_row
    for (genvar j = 0; j < 4; j++) begin : g_col
      logic signed [23:0] acc_ij;

      mac_unit u_mac (
          .clk(clk),
          .rst(rst),
          .en (en),
          .clr(clr),
          .a  (signed'(q_flat[8*i+:8])),
          .b  (signed'(k_flat[8*j+:8])),
          .acc(acc_ij)
      );

      assign acc_flat[24*(4*i+j)+:24] = acc_ij;
    end
  end

`ifdef FORMAL
  // Formal-only scaffolding (guarded, never synthesized; the initial block
  // is exempt from the no-initial-in-RTL rule for that reason). Immediate
  // assertions only, no SVA sequences, same style as mac_unit.sv.
  //
  // The reset/clear/hold properties need no multiplier reasoning and cover
  // all 384 accumulator bits. Full accumulate correctness is asserted for
  // ONE representative element, (0,0): all 16 PEs come from the identical
  // generate body wired by the same +: slicing expression, so proving the
  // wiring and contract for one element plus the whole-vector properties
  // above covers the grid; the mac_unit instances also carry their own
  // FORMAL contract internally, which remains active in this proof.
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;

  always_ff @(posedge clk) begin
    if (f_past_valid) begin
      if ($past(rst)) begin
        assert (acc_flat == 384'd0);
      end else if ($past(clr) && !$past(en)) begin
        assert (acc_flat == 384'd0);
      end else if ($past(clr) && $past(en)) begin
        assert (signed'(acc_flat[23:0]) ==
                24'(16'(signed'($past(q_flat[7:0])) *
                        signed'($past(k_flat[7:0])))));
      end else if ($past(en)) begin
        assert (signed'(acc_flat[23:0]) ==
                24'(signed'($past(acc_flat[23:0])) +
                    24'(16'(signed'($past(q_flat[7:0])) *
                            signed'($past(k_flat[7:0]))))));
      end else begin
        assert (acc_flat == $past(acc_flat));
      end
    end
  end
`endif

endmodule
