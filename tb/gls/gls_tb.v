`timescale 1ns / 1ps
// Gate-level-sim testbench for the online_softmax sky130 netlists (Verilog-
// 2001, iverilog). Replays vectors from scripts/gen_gls_vectors.py and checks
// {m, l, r, w, out_valid} every cycle after reset deasserts. Optional VCD
// dump for power analysis.
// Plusargs: +stim=<file> +exp=<file> +n=<cycles> (required), +vcd=<file>.
// The caller greps for "GLS PASS" (iverilog has no portable exit status).
module gls_tb;

  localparam MAXC = 8192;

  reg clk;
  reg [18:0] stim [0:MAXC-1];
  reg [72:0] expv [0:MAXC-1];

  reg         rst;
  reg         in_valid;
  reg         row_start;
  reg  [15:0] s;
  wire [15:0] w;
  wire [15:0] r;
  wire        out_valid;
  wire [23:0] l;
  wire [15:0] m;

  online_softmax dut (
      .clk(clk),
      .rst(rst),
      .in_valid(in_valid),
      .row_start(row_start),
      .s(s),
      .w(w),
      .r(r),
      .out_valid(out_valid),
      .l(l),
      .m(m)
  );

  integer ncyc;
  integer i;
  integer errors;
  integer checked;
  reg seen_reset_off;
  reg [1023:0] stimf, expf, vcdf;

  // Expected-line fields: {m[15:0], l[23:0], r[15:0], w[15:0], out_valid}
  wire [15:0] e_m = expv[i][72:57];
  wire [23:0] e_l = expv[i][56:33];
  wire [15:0] e_r = expv[i][32:17];
  wire [15:0] e_w = expv[i][16:1];
  wire        e_ov = expv[i][0];

  always #5 clk = ~clk;

  initial begin
    if (!$value$plusargs("stim=%s", stimf)) begin
      $display("GLS FATAL: +stim missing");
      $finish;
    end
    if (!$value$plusargs("exp=%s", expf)) begin
      $display("GLS FATAL: +exp missing");
      $finish;
    end
    if (!$value$plusargs("n=%d", ncyc)) begin
      $display("GLS FATAL: +n missing");
      $finish;
    end
    $readmemh(stimf, stim);
    $readmemh(expf, expv);
    if ($value$plusargs("vcd=%s", vcdf)) begin
      $dumpfile(vcdf);
      $dumpvars(0, dut);
    end

    clk = 1'b0;
    errors = 0;
    checked = 0;
    seen_reset_off = 1'b0;
    {rst, in_valid, row_start, s} = stim[0];

    for (i = 0; i < ncyc; i = i + 1) begin
      // Drive just after the previous posedge, check just before the next.
      {rst, in_valid, row_start, s} = stim[i];
      if (!rst) seen_reset_off = 1'b1;
      #4;
      if (seen_reset_off) begin
        checked = checked + 1;
        if (out_valid !== e_ov) begin
          errors = errors + 1;
          $display("GLS MISMATCH cyc %0d: out_valid=%b exp=%b", i, out_valid, e_ov);
        end
        if (m !== e_m) begin
          errors = errors + 1;
          $display("GLS MISMATCH cyc %0d: m=%h exp=%h", i, m, e_m);
        end
        if (l !== e_l) begin
          errors = errors + 1;
          $display("GLS MISMATCH cyc %0d: l=%h exp=%h", i, l, e_l);
        end
        if (w !== e_w) begin
          errors = errors + 1;
          $display("GLS MISMATCH cyc %0d: w=%h exp=%h", i, w, e_w);
        end
        if (r !== e_r) begin
          errors = errors + 1;
          $display("GLS MISMATCH cyc %0d: r=%h exp=%h", i, r, e_r);
        end
        if (errors > 20) begin
          $display("GLS FAIL: aborting after %0d errors", errors);
          $finish;
        end
      end
      @(posedge clk);
      #1;
    end

    if (errors == 0 && checked > 0)
      $display("GLS PASS: %0d cycles checked, 0 errors", checked);
    else
      $display("GLS FAIL: %0d cycles checked, %0d errors", checked, errors);
    $finish;
  end

endmodule
