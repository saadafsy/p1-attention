`timescale 1ns / 1ps
// online_softmax: per-row online-softmax (m, l) state machine. Third block of
// the datapath (normative spec: docs/uarch.md section 8.2; recurrence:
// section 6; LUT and index math: 3.5; DEN bound: 3.6; rounding: section 4;
// PIPE_ROM pipelining variant: 8.2.1).
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
// Parameter PIPE_ROM (default 0), docs/uarch.md 8.2.1:
//   0: normative single-cycle configuration, out_valid latency 1,
//      bit-identical to the pre-parameter module; the configuration
//      attention_top instantiates.
//   1: Phase 4 timing variant. The critical path diff -> clamp -> index ->
//      ROM -> (l * r multiply) -> rshr -> add is cut at the ROM output:
//      w, r register into a pipe stage (with pipelined valid and row_start
//      context) and the l update runs the next cycle. out_valid latency 2;
//      m stays latency 1 (its compare/mux recurrence must close in one
//      cycle for throughput and has no long path, so visible m leads
//      out_valid by one cycle). Per-element VALUES of m, l, w, r are
//      identical in both configurations; only alignment shifts.
//
// Formats (normative, docs/uarch.md section 2):
//   s, m  : SCORE, signed Q5.10, 16 bits
//   w, r  : WGT, unsigned UQ1.15, 16 bits, values in [0, 0x8000]
//   l     : DEN, unsigned UQ9.15, 24 bits; l * r is a 40-bit (24u x 16u)
//           intermediate, never registered; no saturation anywhere in this
//           module (DEN cannot overflow for row lengths <= 256, proof by
//           induction in uarch.md 3.6; the models assert the bound)
//
// Timing contract, PIPE_ROM = 0 (single-cycle recurrence, no backpressure):
// (m, l) update on the edge that consumes s; w, r, out_valid register on the
// same edge, so in the out_valid cycle the visible l already includes the
// element (w, r) describe. Rows may be back to back (row_start with
// in_valid, no dead cycle). Cycle diagram for a 3-element row (state as
// visible DURING the cycle; mj, lj = state after elements 0..j):
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
// PIPE_ROM = 1 shifts l, w, r, out_valid one cycle right (m unchanged);
// diagram and back-to-back row semantics in uarch.md 8.2.1.
//
// exp LUT: combinational ROM exp_lut_rom() from the GENERATED include
// rtl/exp_lut.svh (emitted only by model/attn.py --emit-lut-svh; same table
// as the sha256-pinned model/exp_lut.hex; rationale in uarch.md 8.2). Two
// lookups per cycle (w and r) are two muxes of the same constant table.
module online_softmax #(
    parameter bit PIPE_ROM = 1'b0  // 0: latency-1 (normative); 1: uarch 8.2.1
) (
    input  logic               clk,
    input  logic               rst,        // synchronous, active-high
    input  logic               in_valid,   // accept score s this cycle
    input  logic               row_start,  // with in_valid: first element of a row
    input  logic signed [15:0] s,          // SCORE Q5.10
    output logic        [15:0] w,          // WGT UQ1.15, registered
    output logic        [15:0] r,          // WGT UQ1.15, registered
    output logic               out_valid,  // w, r valid (1 + PIPE_ROM cycles after accepted s)
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

  // Stage-1 combinational logic, identical in both configurations: base mux,
  // running max, diffs, index math, both ROM lookups.
  logic signed [15:0] m_base;  // state entering this step (row_start override)
  logic signed [15:0] m_n;  // m_new of section 6
  logic signed [16:0] diff_m;  // m_base - m_new, 17-bit, always <= 0
  logic signed [16:0] diff_s;  // s      - m_new, 17-bit, always <= 0
  logic        [10:0] idxp_r;  // pre-clamp indices, in [0, 1024]
  logic        [10:0] idxp_w;
  logic        [ 9:0] idx_r;  // final LUT indices (index clamp, section 5)
  logic        [ 9:0] idx_w;
  logic        [15:0] r_n;  // ROM outputs = next w, r
  logic        [15:0] w_n;

  // All signals assigned unconditionally: no latches.
  always_comb begin
    m_base = row_start ? MInit : m;
    m_n    = (m_base >= s) ? m_base : s;
    diff_m = 17'(m_base) - 17'(m_n);
    diff_s = 17'(s) - 17'(m_n);
    idxp_r = lut_index_pre(diff_m);
    idxp_w = lut_index_pre(diff_s);
    idx_r  = (idxp_r > 11'd1023) ? 10'd1023 : idxp_r[9:0];
    idx_w  = (idxp_w > 11'd1023) ? 10'd1023 : idxp_w[9:0];
    r_n    = exp_lut_rom(idx_r);
    w_n    = exp_lut_rom(idx_w);
  end

  if (PIPE_ROM == 1'b0) begin : g_lat1
    // Normative latency-1 configuration (uarch.md 8.2): the whole recurrence
    // closes in the cycle that consumes s.
    logic [23:0] l_base;
    logic [39:0] lr_prod;  // l * r, 24u x 16u, never registered
    logic [40:0] lr_rnd;  // + 2^14 round-half-up bias
    logic [23:0] l_resc;  // rshr(l * r, 15)
    logic [23:0] l_n;

    always_comb begin
      l_base  = row_start ? 24'd0 : l;
      // Rounding site 3: l = rshr(l * r, 15) + w. Bits above 23 of the
      // shifted value are provably zero for spec-compliant rows (l <= 2^23
      // by the 3.6 induction, r <= 2^15), and l_resc + w < 2^24 likewise;
      // DEN carries no saturation by policy (section 5), so the casts
      // truncate nothing.
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
  end else begin : g_lat2
    // PIPE_ROM = 1 (uarch.md 8.2.1): stage boundary at the ROM output.
    // Stage 1 registers the lookups (w_p, r_p) plus pipelined valid (v_p)
    // and row context (rs_p); m commits in stage 1 (latency 1, required so
    // the next element's diffs see it). Stage 2 runs the l update a cycle
    // later. No l forwarding is needed: the l register IS the stage-2
    // accumulator, its multiply/rshr/add loop closes within stage 2 in one
    // cycle, and rs_p (not the live row_start) selects the l = 0 base so a
    // back-to-back new row cannot corrupt the update in flight.
    logic        v_p;  // stage-1/2 pipe: element in flight
    logic        rs_p;  // pipelined row_start of that element
    logic [15:0] w_p;  // pipelined ROM outputs
    logic [15:0] r_p;
    logic [23:0] l_base;
    logic [39:0] lr_prod;  // l * r, 24u x 16u, never registered
    logic [40:0] lr_rnd;  // + 2^14 round-half-up bias
    logic [23:0] l_resc;  // rshr(l * r, 15)
    logic [23:0] l_n;

    always_comb begin
      l_base  = rs_p ? 24'd0 : l;
      // Rounding site 3, same arithmetic and same non-truncation argument
      // as g_lat1; only the operand registers differ.
      lr_prod = l_base * r_p;
      lr_rnd  = {1'b0, lr_prod} + 41'd16384;
      l_resc  = 24'(lr_rnd >> 15);
      l_n     = l_resc + 24'(w_p);
    end

    always_ff @(posedge clk) begin
      if (rst) begin
        m         <= MInit;
        l         <= 24'd0;
        w         <= 16'd0;
        r         <= 16'd0;
        out_valid <= 1'b0;
        v_p       <= 1'b0;
        rs_p      <= 1'b0;
        w_p       <= 16'd0;
        r_p       <= 16'd0;
      end else begin
        // Stage 1 commit: m plus the pipe registers.
        v_p <= in_valid;
        if (in_valid) begin
          m    <= m_n;
          w_p  <= w_n;
          r_p  <= r_n;
          rs_p <= row_start;
        end
        // Stage 2 commit: the l update and the visible w, r, out_valid.
        out_valid <= v_p;
        if (v_p) begin
          l <= l_n;
          w <= w_p;
          r <= r_p;
        end
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

  // Clamp-logic facts, combinational and configuration-independent: the
  // diffs into the LUT index math are never positive (m_n is the max), and
  // the index clamp works.
  always_comb begin
    assert (diff_m <= 17'sd0);
    assert (diff_s <= 17'sd0);
    assert (idxp_r <= 11'd1024);
    assert (idxp_w <= 11'd1024);
    assert (idx_r <= 10'd1023);
    assert (idx_w <= 10'd1023);
  end

  if (PIPE_ROM == 1'b0) begin : g_f_lat1
    // The audited latency-1 property list, unchanged (uarch.md 8.2).
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
            // m monotone non-decreasing between row starts. Kept alongside
            // the stronger property below (harmless, avoids churn in the
            // audited property list); the exact-max recurrence strictly
            // subsumes it.
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
  end else begin : g_f_lat2
    // PIPE_ROM = 1 properties (uarch.md 8.2.1): the m recurrence is still
    // latency 1 and keeps its exact-max property; l, w, r, out_valid move to
    // latency 2, expressed purely over ports with two cycles of history so
    // no reference into the g_lat2 pipe registers (and no assumption about
    // their free pre-reset value) is needed.
    logic f_past_valid2;
    initial f_past_valid2 = 1'b0;
    always_ff @(posedge clk) f_past_valid2 <= f_past_valid;

    always_ff @(posedge clk) begin
      if (f_past_valid) begin
        if ($past(rst)) begin
          // Reset state (v_p and the pipe registers reset too; port view).
          assert (m == 16'sh8000);
          assert (l == 24'd0);
          assert (out_valid == 1'b0);
        end else if (!$past(in_valid)) begin
          // m hold: stage 1 is untouched without an accepted element.
          assert (m == $past(m));
        end else begin
          // m recurrence, unchanged from the latency-1 configuration.
          if ($past(row_start)) begin
            assert (m == $past(s));
          end else begin
            assert (m >= $past(m));
            assert (m == (($past(s) >= $past(m)) ? $past(s) : $past(m)));
          end
        end
        // Latency-2 alignment: with two clean (reset-free) history cycles,
        // out_valid mirrors in_valid from two cycles earlier, and l, w, r
        // only move when an element was accepted two cycles earlier.
        if (f_past_valid2 && !$past(rst) && !$past(rst, 2)) begin
          assert (out_valid == $past(in_valid, 2));
          if (!$past(in_valid, 2)) begin
            assert (l == $past(l));
            assert (w == $past(w));
            assert (r == $past(r));
          end
        end
      end
    end
  end
`endif

endmodule
