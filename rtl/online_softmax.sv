`timescale 1ns / 1ps
// online_softmax: per-row running max m and denominator l (uarch 6, 8.2).
// Per accepted s, with (m, l) = (-32768, 0) on row_start:
//   m_new = max(m, s); r = lut[idx(m - m_new)]; w = lut[idx(s - m_new)]
//   l <= rshr(l * r, 15) + w
// One LUT argument is always 0, so one subtractor d = s - m and one ROM read
// suffice: d >= 0 gives r = lut[idx(-d)], w = 1.0; d < 0 gives w = lut[idx(d)],
// r = 1.0 (then l <= l + w, exact). FORMAL proves the index equivalence.
// Latency: w, r, l, out_valid 1 + PIPE_ROM cycles after s; m always 1.
// Formats: s, m SCORE Q5.10 s16; w, r WGT UQ1.15 (<= 0x8000); l DEN UQ9.15
// u24, unsaturated (< 2^23 for rows <= 256, uarch 3.6). Rows may be back to
// back.
module online_softmax #(
    parameter bit PIPE_ROM = 1'b0
) (
    input  logic               clk,
    input  logic               rst,        // synchronous, active-high
    input  logic               in_valid,   // accept s this cycle
    input  logic               row_start,  // with in_valid: first element of a row
    input  logic signed [15:0] s,          // SCORE Q5.10
    output logic        [15:0] w,          // WGT UQ1.15, registered
    output logic        [15:0] r,          // WGT UQ1.15, registered
    output logic               out_valid,  // w, r, l valid (1 + PIPE_ROM cycles after s)
    output logic        [23:0] l,          // DEN UQ9.15
    output logic signed [15:0] m           // SCORE Q5.10, running max
);

  `include "rtl/exp_lut.svh"

  localparam logic signed [15:0] MInit = 16'sh8000;  // -32768
  localparam logic [15:0] ExpOne = 16'h8000;  // lut[0] = exp(0) in UQ1.15

  // |d| from two parallel subtractors (no negate in series). The index
  // min(round(min(|d|, 16384) / 16), 1023) is 1023 for |d| >= 16360, else
  // (|d| >> 4) + |d|[3] (round half up).
  logic signed [15:0] m_base;  // m entering this step (row_start override)
  logic signed [16:0] d;  // s - m_base, in [-65535, 65535]
  logic signed [16:0] d_neg;  // m_base - s
  logic               s_max;  // d >= 0: s becomes the running max
  logic signed [15:0] m_n;
  logic        [16:0] d_abs;  // |d|
  logic        [ 9:0] idx;  // the one non-trivial LUT index

  always_comb begin
    m_base = row_start ? MInit : m;
    d      = 17'(s) - 17'(m_base);
    d_neg  = 17'(m_base) - 17'(s);
    s_max  = !d[16];
    m_n    = s_max ? s : m_base;
    d_abs  = s_max ? d : d_neg;
    idx    = (d_abs >= 17'd16360) ? 10'd1023 : 10'(d_abs[13:4] + {9'd0, d_abs[3]});
  end

  // l_next = s_max ? rshr(l_base * q, 15) + 1.0 : l_base + q. The first form
  // is (x + 2^14 + 2^30) >> 15, exact, one adder after the multiplier. Bits
  // above 23 are zero for legal rows (uarch 3.6).
  function automatic logic [23:0] l_next(input logic [23:0] l_base, input logic [15:0] q,
                                         input logic sm);
    // verilator lint_off UNUSEDSIGNAL
    logic [38:0] rnd;  // bits [14:0] are the rounding remainder, dropped by the shift
    // verilator lint_on UNUSEDSIGNAL
    begin
      rnd = 39'(l_base * q) + 39'h4000_4000;  // 2^30 + 2^14
      l_next = sm ? rnd[38:15] : 24'(l_base + 24'(q));
    end
  endfunction

  if (PIPE_ROM == 1'b0) begin : g_lat1
    logic [15:0] q;
    logic [23:0] l_base;

    always_comb begin
      q      = exp_lut_rom(idx);
      l_base = row_start ? 24'd0 : l;
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
          l <= l_next(l_base, q, s_max);
          w <= s_max ? ExpOne : q;
          r <= s_max ? q : ExpOne;
        end
      end
    end
  end else begin : g_lat2
    // Stage 1 registers the ROM output and valid/row_start/s_max; stage 2
    // updates l. rs_p (not the live row_start) picks the l = 0 base so a
    // back-to-back new row cannot corrupt the update in flight.
    logic        v_p;
    logic        rs_p;
    logic        sm_p;
    logic [15:0] q_p;
    logic [23:0] l_base;

`ifdef XILINX_FPGA
    exp_lut_1p_xilinx u_rom (
`else
    exp_lut_1p u_rom (
`endif
        .clk (clk),
        .rst (rst),
        .en  (in_valid),
        .addr(idx),
        .dout(q_p)
    );

    always_comb l_base = rs_p ? 24'd0 : l;

    always_ff @(posedge clk) begin
      if (rst) begin
        m         <= MInit;
        l         <= 24'd0;
        w         <= 16'd0;
        r         <= 16'd0;
        out_valid <= 1'b0;
        v_p       <= 1'b0;
        rs_p      <= 1'b0;
        sm_p      <= 1'b0;
      end else begin
        v_p <= in_valid;
        if (in_valid) begin
          m    <= m_n;
          rs_p <= row_start;
          sm_p <= s_max;
        end
        out_valid <= v_p;
        if (v_p) begin
          l <= l_next(l_base, q_p, sm_p);
          w <= sm_p ? ExpOne : q_p;
          r <= sm_p ? q_p : ExpOne;
        end
      end
    end
  end

`ifdef FORMAL
  // No ROM-content or multiplier reasoning; values are checked in cocotb.
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;

  // Two-lookup spec index (uarch 3.5), x <= 0:
  // idx(x) = min((min(-x, 16384) + 8) >> 4, 1023).
  function automatic logic [9:0] spec_idx(input logic signed [16:0] x);
    logic signed [16:0] xc;
    logic [10:0] p;
    begin
      xc = (x < -17'sd16384) ? -17'sd16384 : x;
      p = 11'((15'(-xc) + 15'd8) >> 4);
      spec_idx = (p > 11'd1023) ? 10'd1023 : p[9:0];
    end
  endfunction

  logic signed [15:0] f_m_spec;
  logic signed [16:0] f_diff_m, f_diff_s;
  always_comb begin
    f_m_spec = (m_base >= s) ? m_base : s;
    f_diff_m = 17'(m_base) - 17'(f_m_spec);
    f_diff_s = 17'(s) - 17'(f_m_spec);
    assert (m_n == f_m_spec);
    assert (f_diff_m <= 17'sd0 && f_diff_s <= 17'sd0);
    assert (d_abs == (d[16] ? 17'(-d) : d));
    // r index is idx when s is the new max, else 0; w index the reverse.
    assert (spec_idx(f_diff_m) == (s_max ? idx : 10'd0));
    assert (spec_idx(f_diff_s) == (s_max ? 10'd0 : idx));
  end

  if (PIPE_ROM == 1'b0) begin : g_f_lat1
    always_ff @(posedge clk) begin
      if (f_past_valid) begin
        if ($past(rst)) begin
          assert (m == 16'sh8000);
          assert (l == 24'd0);
          assert (out_valid == 1'b0);
        end else if (!$past(in_valid)) begin
          // No accepted element: everything holds, out_valid low.
          assert (m == $past(m));
          assert (l == $past(l));
          assert (w == $past(w));
          assert (r == $past(r));
          assert (out_valid == 1'b0);
        end else begin
          assert (out_valid == 1'b1);
          if ($past(row_start)) begin
            assert (m == $past(s));
          end else begin
            // Exact max recurrence (subsumes monotonicity).
            assert (m == (($past(s) >= $past(m)) ? $past(s) : $past(m)));
          end
          // One of w, r is always exp(0).
          assert (w == ExpOne || r == ExpOne);
        end
      end
    end
  end else begin : g_f_lat2
    logic f_past_valid2;
    initial f_past_valid2 = 1'b0;
    always_ff @(posedge clk) f_past_valid2 <= f_past_valid;

    always_ff @(posedge clk) begin
      if (f_past_valid) begin
        if ($past(rst)) begin
          assert (m == 16'sh8000);
          assert (l == 24'd0);
          assert (out_valid == 1'b0);
        end else if (!$past(in_valid)) begin
          assert (m == $past(m));
        end else begin
          if ($past(row_start)) begin
            assert (m == $past(s));
          end else begin
            assert (m == (($past(s) >= $past(m)) ? $past(s) : $past(m)));
          end
        end
        // Latency 2: out_valid, l, w, r follow in_valid two cycles back.
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
