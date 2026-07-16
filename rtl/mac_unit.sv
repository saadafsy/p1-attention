`timescale 1ns / 1ps
// mac_unit: ACT x ACT multiply, SACC accumulate. First block of the Q.K^T
// datapath (docs/uarch.md sections 3.1, 3.2, 8).
//
// Formats (normative, docs/uarch.md):
//   a, b : ACT,  signed Q1.6,   8 bits
//   a*b  : exact signed product, 16 bits, |value| <= 4.0 (only (-2)*(-2))
//   acc  : SACC, signed Q11.12, 24 bits; exact accumulation, no rounding,
//          no saturation; overflow impossible for dot lengths <= 511
//          (proof in uarch.md 3.2; D = 16 here, bound asserted in models/TB)
//
// Control contract (one cycle, all synchronous):
//   rst          : acc <= 0
//   clr=1, en=1  : acc <= a*b        (start a new dot product, no dead cycle)
//   clr=1, en=0  : acc <= 0
//   clr=0, en=1  : acc <= acc + a*b
//   clr=0, en=0  : hold
module mac_unit (
    input  logic               clk,
    input  logic               rst,  // synchronous, active-high
    input  logic               en,   // accept a*b this cycle
    input  logic               clr,  // start new accumulation this cycle
    input  logic signed [ 7:0] a,    // ACT Q1.6
    input  logic signed [ 7:0] b,    // ACT Q1.6
    output logic signed [23:0] acc   // SACC Q11.12
);

  logic signed [15:0] prod;
  logic signed [23:0] base;
  logic signed [23:0] acc_n;

  // All outputs assigned on all paths: no latches.
  always_comb begin
    prod  = a * b;               // exact 16-bit signed product
    base  = clr ? 24'sd0 : acc;
    acc_n = en ? base + 24'(prod) : base;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      acc <= '0;
    end else begin
      acc <= acc_n;
    end
  end

`ifdef FORMAL
  // Formal-only scaffolding (guarded, never synthesized; the initial block
  // below is exempt from the no-initial-in-RTL rule for that reason).
  // Properties restate the control contract from the header, minimal and
  // yosys-parseable: immediate assertions only, no SVA sequences.
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;

  always_ff @(posedge clk) begin
    if (f_past_valid) begin
      if ($past(rst)) begin
        assert (acc == 24'sd0);
      end else if ($past(clr) && !$past(en)) begin
        assert (acc == 24'sd0);
      end else if ($past(clr) && $past(en)) begin
        assert (acc == 24'(16'($past(a) * $past(b))));
      end else if ($past(en)) begin
        assert (acc == 24'($past(acc) + 24'(16'($past(a) * $past(b)))));
      end else begin
        assert (acc == $past(acc));
      end
    end
  end
`endif

endmodule
