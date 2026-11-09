`timescale 1ns / 1ps
// matmul_tile: 4x4 output-stationary block of S = Q.K^T (uarch 8.1), 16
// mac_unit instances. Per enabled cycle MAC (i, j) adds q_i[d] * k_j[d];
// Q elements broadcast across columns, K down rows. Structural only.
// Packing (element 0 in the low bits):
//   q_flat[8*i +: 8], k_flat[8*j +: 8]: ACT Q1.6
//   acc_flat[24*(4*i+j) +: 24]: SACC Q11.12, exact for dot lengths <= 511
// Control is mac_unit's, shared by all 16: clr=1,en=1 loads q*k (no dead
// cycle); clr=1,en=0 clears; clr=0,en=1 accumulates; else hold.
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
  // Reset/clear/hold are checked on all 384 bits; accumulate only on element
  // (0,0), since all PEs share one generate body and each mac_unit carries
  // its own FORMAL contract.
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
