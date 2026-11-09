`timescale 1ns / 1ps
// mac_unit: ACT x ACT multiply, SACC accumulate (uarch 3.1, 3.2).
//   a, b : ACT Q1.6 s8
//   a*b  : exact s16, |value| <= 4.0 (only (-2)*(-2))
//   acc  : SACC Q11.12 s24; no rounding or saturation, cannot overflow for
//          dot lengths <= 511 (uarch 3.2; D = 16 here)
// Control (synchronous):
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

  always_comb begin
    prod  = a * b;               // exact 16-bit signed product
    base  = clr ? 24'sd0 : acc;
`ifdef INJECT_BUG
    // Deliberate mutation for `make -C tb/uvm bug-proof` only: clr is ignored
    // when en is high. Proves the UVM environment catches a wrong RTL.
    acc_n = en ? acc + 24'(prod) : base;
`else
    acc_n = en ? base + 24'(prod) : base;
`endif
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      acc <= '0;
    end else begin
      acc <= acc_n;
    end
  end

`ifdef FORMAL
  // The control contract from the header, as immediate assertions.
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
