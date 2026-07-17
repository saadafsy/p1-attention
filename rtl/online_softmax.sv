`timescale 1ns / 1ps
// online_softmax: per-row online-softmax (m, l) state machine. Third block of
// the datapath (normative spec: docs/uarch.md section 8.2; recurrence:
// section 6; LUT and index math: 3.5; DEN bound: 3.6; rounding: section 4).
//
// Function, per accepted score s (in_valid = 1), with base state
// (m, l) = (-32768, 0) when row_start is also high (section 6 init):
//   m_new = max(m, s)
//   r     = lut[ idx(m - m_new) ]     rescale factor, WGT UQ1.15
//   w     = lut[ idx(s - m_new) ]     this element's weight, WGT UQ1.15
//   l     <= rshr(l * r, 15) + w      DEN UQ9.15 (rounding site 3)
//   m     <= m_new
// idx(): 17-bit signed diff, clamp to -16384, then min((-d + 8) >> 4, 1023)
// (rounding site 2). rshr(x, 15) = (x + 2^14) >> 15, round-half-up.
// The NUM path and the final division live in attention_top, not here.
//
// Formats (normative, docs/uarch.md section 2):
//   s, m  : SCORE, signed Q5.10, 16 bits
//   w, r  : WGT, unsigned UQ1.15, 16 bits, values in [0, 0x8000]
//   l     : DEN, unsigned UQ9.15, 24 bits; l * r is a 40-bit (24u x 16u)
//           intermediate, never registered; no saturation anywhere in this
//           module (DEN cannot overflow for row lengths <= 256, proof by
//           induction in uarch.md 3.6; the models assert the bound)
//
// Timing contract (single-cycle recurrence, no backpressure): (m, l) update
// on the edge that consumes s; w, r, out_valid register on the same edge, so
// in the out_valid cycle the visible l already includes the element (w, r)
// describe. Rows may be back to back (row_start with in_valid, no dead
// cycle). Cycle diagram for a 3-element row (state as visible DURING the
// cycle; mj, lj = state after elements 0..j):
//
//   cycle       |  0   |  1     |  2     |  3     |  4
//   in_valid    |  1   |  1     |  1     |  0     |  0
//   row_start   |  1   |  0     |  0     |  0     |  0
//   s           |  s0  |  s1    |  s2    |  x     |  x
//   m (visible) |  old |  s0    |  m1    |  m2    |  m2
//   l (visible) |  old |  l0    |  l1    |  l2    |  l2
//   out_valid   |  0   |  1     |  1     |  1     |  0
//   w (visible) |  x   |  w(s0) |  w(s1) |  w(s2) |  w(s2)
//   r (visible) |  x   |  r(s0) |  r(s1) |  r(s2) |  r(s2)
//
// exp LUT: combinational ROM exp_lut_rom() from the GENERATED include
// rtl/exp_lut.svh (emitted only by model/attn.py --emit-lut-svh; same table
// as the sha256-pinned model/exp_lut.hex; rationale in uarch.md 8.2). Two
// lookups per cycle (w and r) are two muxes of the same constant table.
module online_softmax (
    input  logic               clk,
    input  logic               rst,        // synchronous, active-high
    input  logic               in_valid,   // accept score s this cycle
    input  logic               row_start,  // with in_valid: first element of a row
    input  logic signed [15:0] s,          // SCORE Q5.10
    output logic        [15:0] w,          // WGT UQ1.15, registered
    output logic        [15:0] r,          // WGT UQ1.15, registered
    output logic               out_valid,  // w, r valid (one cycle after accepted s)
    output logic        [23:0] l,          // DEN UQ9.15, current denominator
    output logic signed [15:0] m           // SCORE Q5.10, current running max
);

  `include "rtl/exp_lut.svh"

  // Section 6 init values: most negative SCORE, empty denominator.
  localparam logic signed [15:0] MInit = 16'sh8000;  // -32768

  // Pre-clamp LUT index of uarch.md 3.5 for a Q5.10 difference d <= 0:
  // clamp to the domain floor -16384 (-16.0), negate, round-half-up to the
  // 2^-6 grid. Result range [0, 1024]; the final min(., 1023) clamp is done
  // by the caller so the pre-clamp value stays visible to the formal block.
  function automatic logic [10:0] lut_index_pre(input logic signed [16:0] d);
    logic signed [16:0] d_c;
    logic [14:0] nd;
    begin
      d_c = (d < -17'sd16384) ? -17'sd16384 : d;  // diff clamp (section 5)
      nd = 15'(-d_c);  // in [0, 16384], 15 bits
      lut_index_pre = 11'((nd + 15'd8) >> 4);  // rounding site 2
    end
  endfunction

  logic signed [15:0] m_base;  // state entering this step (row_start override)
  logic        [23:0] l_base;
  logic signed [15:0] m_n;  // m_new of section 6
  logic signed [16:0] diff_m;  // m_base - m_new, 17-bit, always <= 0
  logic signed [16:0] diff_s;  // s      - m_new, 17-bit, always <= 0
  logic        [10:0] idxp_r;  // pre-clamp indices, in [0, 1024]
  logic        [10:0] idxp_w;
  logic        [ 9:0] idx_r;  // final LUT indices (index clamp, section 5)
  logic        [ 9:0] idx_w;
  logic        [15:0] r_n;  // ROM outputs = next w, r
  logic        [15:0] w_n;
  logic        [39:0] lr_prod;  // l * r, 24u x 16u, never registered
  logic        [40:0] lr_rnd;  // + 2^14 round-half-up bias
  logic        [23:0] l_resc;  // rshr(l * r, 15)
  logic        [23:0] l_n;

  // All signals assigned unconditionally: no latches.
  always_comb begin
    m_base  = row_start ? MInit : m;
    l_base  = row_start ? 24'd0 : l;
    m_n     = (m_base >= s) ? m_base : s;
    diff_m  = 17'(m_base) - 17'(m_n);
    diff_s  = 17'(s) - 17'(m_n);
    idxp_r  = lut_index_pre(diff_m);
    idxp_w  = lut_index_pre(diff_s);
    idx_r   = (idxp_r > 11'd1023) ? 10'd1023 : idxp_r[9:0];
    idx_w   = (idxp_w > 11'd1023) ? 10'd1023 : idxp_w[9:0];
    r_n     = exp_lut_rom(idx_r);
    w_n     = exp_lut_rom(idx_w);
    // Rounding site 3: l = rshr(l * r, 15) + w. Bits above 23 of the shifted
    // value are provably zero for spec-compliant rows (l <= 2^23 by the 3.6
    // induction, r <= 2^15), and l_resc + w < 2^24 likewise; DEN carries no
    // saturation by policy (section 5), so the casts truncate nothing.
    lr_prod = l_base * r_n;
    lr_rnd  = {1'b0, lr_prod} + 41'd16384;
    l_resc  = 24'(lr_rnd >> 15);
    l_n     = l_resc + 24'(w_n);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      m         <= MInit;
      l         <= 24'd0;
      w         <= 16'd0;
      r         <= 16'd0;
      out_valid <= 1'b0;
    end else begin
      out_valid <= in_valid;
      if (in_valid) begin
        m <= m_n;
        l <= l_n;
        w <= w_n;
        r <= r_n;
      end
    end
  end

`ifdef FORMAL
  // Formal-only scaffolding (guarded, never synthesized; the initial block
  // is exempt from the no-initial-in-RTL rule for that reason). Immediate
  // assertions only, same style as mac_unit.sv. Solver-conscious: nothing
  // below requires reasoning about ROM contents or multiplier correctness
  // (those are the cocotb TB's job, checked against model/attn.py).
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;

  // Clamp-logic facts, combinational: the diffs into the LUT index math are
  // never positive (m_n is the max), and the index clamp works.
  always_comb begin
    assert (diff_m <= 17'sd0);
    assert (diff_s <= 17'sd0);
    assert (idxp_r <= 11'd1024);
    assert (idxp_w <= 11'd1024);
    assert (idx_r <= 10'd1023);
    assert (idx_w <= 10'd1023);
  end

  always_ff @(posedge clk) begin
    if (f_past_valid) begin
      if ($past(rst)) begin
        // Reset state.
        assert (m == 16'sh8000);
        assert (l == 24'd0);
        assert (out_valid == 1'b0);
      end else if (!$past(in_valid)) begin
        // Hold: no accepted element, nothing moves, no stale out_valid.
        assert (m == $past(m));
        assert (l == $past(l));
        assert (w == $past(w));
        assert (r == $past(r));
        assert (out_valid == 1'b0);
      end else begin
        // Accepted element: out_valid rises exactly one cycle later.
        assert (out_valid == 1'b1);
        if ($past(row_start)) begin
          // Section 6 identity 2 (max part): first element sets m = s0.
          assert (m == $past(s));
        end else begin
          // m monotone non-decreasing between row starts. Kept alongside the
          // stronger property below (harmless, avoids churn in the audited
          // property list); the exact-max recurrence strictly subsumes it.
          assert (m >= $past(m));
          // Formal-coverage auditor finding: the monotonicity assert above
          // passes even if m latched a wrong value larger than $past(m) (a
          // bug that overshoots the true max would still look monotonic).
          // This property pins m to the exact section-6 recurrence
          // m_new = max(m, s), evaluated only over $past(s)/$past(m) (a
          // comparison and a mux over already-registered values, no ROM or
          // multiplier reasoning), so it strictly subsumes monotonicity.
          assert (m == (($past(s) >= $past(m)) ? $past(s) : $past(m)));
        end
      end
    end
  end
`endif

endmodule
