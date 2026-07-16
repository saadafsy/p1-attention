`timescale 1ns / 1ps
// attention_top: 4-row-blocked streaming attention integration. Phase 2:
// stitches the three verified, UNMODIFIED submodules (mac_unit, matmul_tile,
// online_softmax) into the full Section 6 recurrence over n_len query and
// key/value rows. Normative spec: docs/uarch.md 8.3 (this section documents
// every design choice below in prose); formats: Section 2; rounding sites
// 1 (score conversion) and 5 (output division), plus the online_softmax
// rounding sites 2/3 and this module's own numerator rescale (site 4, 3.7)
// are ALL implemented here, bit-identical to model/attn.py attn_fixed.
//
// Formats used directly in this module (docs/uarch.md Section 2):
//   ACT   Q1.6   signed  8 bits   Q, K, V inputs and final output
//   SACC  Q11.12 signed 24 bits   matmul_tile's per-block accumulator
//   SCORE Q5.10  signed 16 bits   converted score s (rounding site 1)
//   WGT   UQ1.15 unsigned 16 bits online_softmax's w, r
//   DEN   UQ9.15 unsigned 24 bits online_softmax's l (read here, not owned)
//   NUM   Q10.21 signed  32 bits  this module's acc[lane][k] (rounding site 4)
//
// Dataflow (docs/uarch.md 8.3): query rows in groups of 4 ("lanes"); per
// group, key/value blocks of 4 stream through matmul_tile one D=16-cycle
// block at a time (S_COMPUTE). While block kb computes, block kb-1 (already
// finished, captured into drain_buf at the previous block boundary) is
// drained into 4 online_softmax instances, one score per lane every 4
// cycles, round-robin: lane = t[1:0], key_local = t[3:2]. The final block of
// a group has no "next block" compute to overlap with, so S_DRAIN_LAST
// spends one more 16-cycle window draining it alone. Then S_DIVIDE runs a
// 16-wide bank of serial restoring dividers (docs/uarch.md 3.8) once per
// row, 4 rows sequential, 35 cycles each (1 load + 33 iterate + 1 write).
//
// mac_unit, matmul_tile, online_softmax are instantiated verbatim (their own
// verified control/format contracts, docs/uarch.md 8.1/8.2); NOT modified.
module attention_top (
    input  logic        clk,
    input  logic        rst,        // synchronous, active-high

    // Load port: shared byte-granular synchronous write into Q/K/V RAMs.
    input  logic [ 1:0] sel,        // 0=Q, 1=K, 2=V, 3=unused (no write)
    input  logic [ 9:0] addr,       // {row[5:0], col[3:0]}
    input  logic [ 7:0] wdata,      // ACT Q1.6
    input  logic        we,

    // Config + control.
    // verilator lint_off UNUSEDSIGNAL
    // n_len[1:0] is never read: the 8.3 contract requires n_len to be a
    // multiple of 4, so only n_len[6:2] (the block/group count) matters.
    input  logic [ 6:0] n_len,      // multiple of 4, 4 <= n_len <= 64
    // verilator lint_on UNUSEDSIGNAL
    input  logic        start,      // pulse; accepted only when busy = 0
    output logic        busy,
    output logic        done,       // one-cycle pulse, the cycle busy falls

    // Output buffer: registered synchronous read port.
    input  logic [ 9:0] rd_addr,    // {row[5:0], col[3:0]}
    output logic [ 7:0] rd_data,    // ACT Q1.6, valid one cycle after rd_addr

    // Phase 2 benchmark counter.
    output logic [31:0] cycle_count
);

  // ---------------------------------------------------------------------
  // Internal storage: plain register-array RAMs (no $readmemh, no memory
  // macro). Byte-granular write port; whole-row combinational reads for the
  // tile feed and the drain path.
  // ---------------------------------------------------------------------
  logic signed [7:0] q_mem[64][16];
  logic signed [7:0] k_mem[64][16];
  logic signed [7:0] v_mem[64][16];
  logic signed [7:0] out_mem[64][16];

  wire [5:0] wr_row = addr[9:4];
  wire [3:0] wr_col = addr[3:0];

  genvar gr, gc;
  for (gr = 0; gr < 64; gr++) begin : g_mem_row
    for (gc = 0; gc < 16; gc++) begin : g_mem_col
      always_ff @(posedge clk) begin
        if (rst) begin
          q_mem[gr][gc]   <= '0;
          k_mem[gr][gc]   <= '0;
          v_mem[gr][gc]   <= '0;
          out_mem[gr][gc] <= '0;
        end else begin
          if (we && sel == 2'd0 && wr_row == gr[5:0] && wr_col == gc[3:0])
            q_mem[gr][gc] <= wdata;
          if (we && sel == 2'd1 && wr_row == gr[5:0] && wr_col == gc[3:0])
            k_mem[gr][gc] <= wdata;
          if (we && sel == 2'd2 && wr_row == gr[5:0] && wr_col == gc[3:0])
            v_mem[gr][gc] <= wdata;
          if (out_we && out_wr_row == gr[5:0])
            out_mem[gr][gc] <= out_wr_data[gc];
        end
      end
    end
  end

  // Registered output read port.
  always_ff @(posedge clk) begin
    if (rst) rd_data <= '0;
    else rd_data <= out_mem[rd_addr[9:4]][rd_addr[3:0]];
  end

  // ---------------------------------------------------------------------
  // Main FSM.
  // ---------------------------------------------------------------------
  typedef enum logic [1:0] {
    S_IDLE,
    S_COMPUTE,
    S_DRAIN_LAST,
    S_DIVIDE
  } state_e;

  state_e state, state_n;

  logic [4:0] nblk_reg;   // n_len/4, latched at start; range [1, 16]
  logic [3:0] rg;         // query row group index, < nblk_reg
  logic [3:0] kb;         // key/value block index, < nblk_reg
  logic [3:0] t;          // in-block cycle counter, 0..15 (also the d index)
  logic [1:0] row;        // current divide row within the group, 0..3
  logic [5:0] div_cnt;    // 0=load, 1..33=iterate, 34=write

  assign busy = (state != S_IDLE);

  // nblk_reg - 1, as the 4-bit value kb/rg compare against. Computed from
  // the full 5-bit nblk_reg (so bit 4, needed for nblk_reg == 16, is used):
  // nblk_reg in [1,16] so this 5-bit subtraction never borrows past bit 4,
  // and truncating to 4 bits gives exactly (nblk-1) mod 16, which is the
  // value kb/rg (both < 16) must match.
  // verilator lint_off UNUSEDSIGNAL
  // Bit 4 of the 5-bit subtraction is read implicitly: nblk_reg in [1,16]
  // means (nblk_reg - 1) never needs to borrow from a bit above 4, so the
  // low 4 bits already equal (nblk-1) mod 16, the exact value kb/rg (both
  // < 16) compare against; bit 4 of the result is provably always 0 for
  // nblk_reg < 16 and provably discarded-but-correct (via wraparound) for
  // nblk_reg == 16, so keeping the subtraction at full 5-bit width (rather
  // than truncating nblk_reg first) is the documented, deliberate choice.
  logic [4:0] nblk_m1_full;
  assign nblk_m1_full = nblk_reg - 5'd1;
  wire [3:0] nblk_m1 = nblk_m1_full[3:0];
  // verilator lint_on UNUSEDSIGNAL

  // ---------------------------------------------------------------------
  // matmul_tile feed (S_COMPUTE only).
  // ---------------------------------------------------------------------
  logic        tile_en;
  logic        tile_clr;
  logic [31:0] q_flat;
  logic [31:0] k_flat;
  logic [383:0] acc_flat;

  always_comb begin
    tile_en  = (state == S_COMPUTE);
    tile_clr = (state == S_COMPUTE) && (t == 4'd0);
  end

  for (genvar gi = 0; gi < 4; gi++) begin : g_qfeed
    assign q_flat[8*gi+:8] = q_mem[{rg, gi[1:0]}][t];
  end
  for (genvar gj = 0; gj < 4; gj++) begin : g_kfeed
    assign k_flat[8*gj+:8] = k_mem[{kb, gj[1:0]}][t];
  end

  matmul_tile u_tile (
      .clk (clk),
      .rst (rst),
      .en  (tile_en),
      .clr (tile_clr),
      .q_flat(q_flat),
      .k_flat(k_flat),
      .acc_flat(acc_flat)
  );

  // Double buffer: capture the just-finished block at the boundary edge
  // (t == 15), before the next clr overwrites the tile's own accumulators.
  // acc_flat is matmul_tile's OWN registered output; at the same edge that
  // ends the t==15 cycle, its internal mac_units have not yet folded in
  // this cycle's (d=15) product (NBA semantics: a same-edge register-to-
  // register read always sees the pre-edge value), so acc_flat here still
  // reflects only d=0..14. drain_buf_next adds the missing d=15 product
  // (computed combinationally from this cycle's own q_flat/k_flat, which
  // are exactly the d=15 operands) so the captured value is the exact,
  // complete D=16 SACC block, matching mac_unit's own D<=511 exactness
  // (uarch.md 3.2) with no extra pipeline cycle and no window-straddling
  // read timing elsewhere in this module.
  logic [383:0] drain_buf;
  logic [383:0] drain_buf_next;

  for (genvar cri = 0; cri < 4; cri++) begin : g_cap_row
    for (genvar crj = 0; crj < 4; crj++) begin : g_cap_col
      assign drain_buf_next[24*(4*cri+crj)+:24] =
          24'(signed'(acc_flat[24*(4*cri+crj)+:24]) +
              24'(signed'(q_flat[8*cri+:8]) * signed'(k_flat[8*crj+:8])));
    end
  end

  always_ff @(posedge clk) begin
    if (rst) drain_buf <= '0;
    else if ((state == S_COMPUTE) && (t == 4'd15)) drain_buf <= drain_buf_next;
  end

  // ---------------------------------------------------------------------
  // Drain / round-robin addressing.
  // ---------------------------------------------------------------------
  wire [1:0] lane      = t[1:0];
  wire [1:0] key_local = t[3:2];

  logic       drain_en;
  logic [3:0] drain_blk;   // block index whose scores are being drained now

  always_comb begin
    drain_en  = ((state == S_COMPUTE) && (kb != 4'd0)) || (state == S_DRAIN_LAST);
    drain_blk = (state == S_DRAIN_LAST) ? (nblk_m1) : (kb - 4'd1);
  end

  wire [5:0] drain_v_row = {drain_blk, key_local};

  // Score conversion (rounding site 1, uarch.md 3.3): one element per
  // cycle, whichever (lane, key_local) is addressed this cycle.
  // acc_flat[24*(4*i+j)+:24], i=lane, j=key_local -> index = 4*lane+key_local
  wire [3:0] drain_elem_idx = {lane, key_local};
  wire signed [23:0] drain_sacc = drain_buf[24*drain_elem_idx+:24];

  logic signed [24:0] s_wide;
  logic signed [24:0] s_shift;
  logic signed [15:0] s_conv;

  always_comb begin
    s_wide  = 25'(signed'(drain_sacc)) + 25'sd8;
    s_shift = s_wide >>> 4;
    if (s_shift > 25'sd32767) s_conv = 16'sd32767;
    else if (s_shift < -25'sd32768) s_conv = -16'sd32768;
    else s_conv = s_shift[15:0];
  end

  logic       row_start_val;
  always_comb row_start_val = drain_en && (key_local == 2'd0) && (drain_blk == 4'd0);

  // ---------------------------------------------------------------------
  // 4 online_softmax lanes.
  // ---------------------------------------------------------------------
  logic        lane_in_valid  [4];
  logic        lane_row_start [4];
  logic [15:0] lane_w  [4];
  logic [15:0] lane_r  [4];
  logic        lane_out_valid [4];
  logic [23:0] lane_l  [4];
  // verilator lint_off UNUSEDSIGNAL
  // online_softmax's m is "continuously visible (debug and formal)" per its
  // own port contract (uarch.md 8.2); this integration path needs only w,
  // r and l, so the wire is connected (required, it is an output port of an
  // already-verified module) but intentionally never read here.
  logic [15:0] lane_m  [4];
  // verilator lint_on UNUSEDSIGNAL

  for (genvar gL = 0; gL < 4; gL++) begin : g_softmax
    always_comb begin
      lane_in_valid[gL]  = drain_en && (lane == gL[1:0]);
      lane_row_start[gL] = row_start_val && (lane == gL[1:0]);
    end

    online_softmax u_sm (
        .clk      (clk),
        .rst      (rst),
        .in_valid (lane_in_valid[gL]),
        .row_start(lane_row_start[gL]),
        .s        (s_conv),
        .w        (lane_w[gL]),
        .r        (lane_r[gL]),
        .out_valid(lane_out_valid[gL]),
        .l        (lane_l[gL]),
        .m        (lane_m[gL])
    );
  end

  // One-cycle pipeline registers: carry row_start and the V row address
  // from the in_valid cycle to the out_valid cycle (mirrors online_softmax's
  // own row_start -> l_base alignment, uarch.md 8.3).
  logic        row_start_d [4];
  logic [5:0]  vrow_pipe   [4];

  for (genvar gP = 0; gP < 4; gP++) begin : g_pipe
    always_ff @(posedge clk) begin
      if (rst) begin
        row_start_d[gP] <= 1'b0;
        vrow_pipe[gP]   <= '0;
      end else if (lane_in_valid[gP]) begin
        row_start_d[gP] <= lane_row_start[gP];
        vrow_pipe[gP]   <= drain_v_row;
      end
    end
  end

  // ---------------------------------------------------------------------
  // NUM accumulators (rounding site 4, uarch.md 3.7/6.1): 4 lanes x 16 k.
  // ---------------------------------------------------------------------
  logic signed [31:0] acc_num [4][16];

  for (genvar gL2 = 0; gL2 < 4; gL2++) begin : g_num_lane
    for (genvar gK = 0; gK < 16; gK++) begin : g_num_k
      logic signed [31:0] acc_base;
      logic signed [48:0] ar_full;
      logic signed [48:0] ar_rnd;
      logic signed [23:0] wv_prod;
      logic signed [31:0] acc_next;

      // rshr(acc_base * r, 15): 48-bit signed product (3.7/6.1), round-
      // half-up bias then arithmetic shift; only the low 32 bits of the
      // shifted value are kept (32'() cast), matching online_softmax's own
      // l_resc truncation style (8.2) and trusted by the same 3.7 bound.
      always_comb begin
        acc_base = row_start_d[gL2] ? 32'sd0 : acc_num[gL2][gK];
        ar_full  = 49'(signed'(acc_base) * signed'({1'b0, lane_r[gL2]}));
        ar_rnd   = ar_full + 49'sd16384;
        wv_prod  = 24'(signed'({1'b0, lane_w[gL2]}) * signed'(v_mem[vrow_pipe[gL2]][gK]));
        if (lane_out_valid[gL2]) acc_next = 32'(ar_rnd >>> 15) + 32'(wv_prod);
        else acc_next = acc_num[gL2][gK];
      end

      always_ff @(posedge clk) begin
        if (rst) acc_num[gL2][gK] <= '0;
        else acc_num[gL2][gK] <= acc_next;
      end
    end
  end

  // ---------------------------------------------------------------------
  // Divider bank (uarch.md 3.8, rounding site 5): 16-wide, shared control
  // (div_cnt, row), one instance per k. B (= 2*den) is shared per row.
  // ---------------------------------------------------------------------
  wire [23:0] div_den = lane_l[row];
  wire [24:0] div_b   = {div_den, 1'b0};  // B = 2*den, 25-bit unsigned

  wire [5:0] out_wr_row = {rg, row};
  logic        out_we;
  logic [7:0]  out_wr_data [16];
  assign out_we = (state == S_DIVIDE) && (div_cnt == 6'd34);

  for (genvar gD = 0; gD < 16; gD++) begin : g_div
    logic signed [33:0] a_val;      // A = 2*num + den, 34-bit signed
    // verilator lint_off UNUSEDSIGNAL
    // abs_a_full[33] and rem_trial[25] are provably always 0 by the 3.8
    // width bounds (|A| < 2^33, and the restoring-division invariant keeps
    // the trial subtraction's result < B < 2^25 whenever it is selected);
    // both are kept full-width only so the intermediate arithmetic
    // (negation, subtraction) cannot silently truncate, matching the width
    // discipline of online_softmax's lr_prod/lr_rnd (8.2). Only the
    // guaranteed-zero top bit goes unread.
    logic signed [33:0] abs_a_full;
    logic        [25:0] rem_trial;
    // verilator lint_on UNUSEDSIGNAL
    logic        [32:0] abs_a_val;  // |A|, fits in 33 bits
    logic               sign_a_val;

    logic        [32:0] abs_a_reg;
    logic               sign_a_reg;
    logic        [24:0] rem_reg;
    logic        [32:0] qt_reg;

    logic signed [6:0]  bit_idx_s;  // 33 - div_cnt, clamped
    logic        [5:0]  bit_idx;
    logic               new_bit;
    logic        [25:0] rem_shift;
    logic        [24:0] rem_next;
    logic        [32:0] qt_next;

    logic signed [33:0] q_signed;
    logic signed [33:0] q_sat_in;
    logic signed [7:0]  out_raw;

    always_comb begin
      a_val      = (34'(signed'(acc_num[row][gD])) <<< 1) + 34'(signed'({1'b0, div_den}));
      abs_a_full = a_val[33] ? (-a_val) : a_val;
      abs_a_val  = abs_a_full[32:0];
      sign_a_val = a_val[33];

      // bit_idx = 33 - div_cnt, valid (0..32) only for div_cnt in [1,33];
      // clamped to 0 outside that range (unused there, guarded below).
      bit_idx_s = 7'sd33 - {1'b0, div_cnt};
      bit_idx   = (bit_idx_s < 7'sd0 || bit_idx_s > 7'sd32) ? 6'd0 : bit_idx_s[5:0];
      new_bit   = abs_a_reg[bit_idx];
      rem_shift = {rem_reg, new_bit};
      rem_trial = rem_shift - {1'b0, div_b};
      if (rem_shift >= {1'b0, div_b}) begin
        rem_next = rem_trial[24:0];
        qt_next  = {qt_reg[31:0], 1'b1};
      end else begin
        rem_next = rem_shift[24:0];
        qt_next  = {qt_reg[31:0], 1'b0};
      end

      q_signed = sign_a_reg ? -(34'(qt_reg) + (rem_reg != 25'd0 ? 34'sd1 : 34'sd0)) : 34'(qt_reg);
      q_sat_in = q_signed;
      if (q_sat_in > 34'sd127) out_raw = 8'sd127;
      else if (q_sat_in < -34'sd128) out_raw = -8'sd128;
      else out_raw = q_sat_in[7:0];
    end

    always_ff @(posedge clk) begin
      if (rst) begin
        abs_a_reg  <= '0;
        sign_a_reg <= 1'b0;
        rem_reg    <= '0;
        qt_reg     <= '0;
      end else if (state == S_DIVIDE) begin
        if (div_cnt == 6'd0) begin
          abs_a_reg  <= abs_a_val;
          sign_a_reg <= sign_a_val;
          rem_reg    <= '0;
          qt_reg     <= '0;
        end else if (div_cnt >= 6'd1 && div_cnt <= 6'd33) begin
          rem_reg <= rem_next;
          qt_reg  <= qt_next;
        end
      end
    end

    assign out_wr_data[gD] = out_raw;
  end

  // ---------------------------------------------------------------------
  // FSM sequencing.
  // ---------------------------------------------------------------------
  always_comb begin
    state_n = state;
    unique case (state)
      S_IDLE: begin
        if (start) state_n = S_COMPUTE;
        else state_n = S_IDLE;
      end
      S_COMPUTE: begin
        if (t == 4'd15) begin
          if (kb == nblk_m1) state_n = S_DRAIN_LAST;
          else state_n = S_COMPUTE;
        end
      end
      S_DRAIN_LAST: begin
        if (t == 4'd15) state_n = S_DIVIDE;
        else state_n = S_DRAIN_LAST;
      end
      S_DIVIDE: begin
        if (div_cnt == 6'd34 && row == 2'd3) begin
          if (rg == nblk_m1) state_n = S_IDLE;
          else state_n = S_COMPUTE;
        end
      end
      default: state_n = S_IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state    <= S_IDLE;
      nblk_reg <= '0;
      rg       <= '0;
      kb       <= '0;
      t        <= '0;
      row      <= '0;
      div_cnt  <= '0;
      done     <= 1'b0;
    end else begin
      state <= state_n;
      done  <= 1'b0;

      unique case (state)
        S_IDLE: begin
          if (start) begin
            nblk_reg <= n_len[6:2];
            rg       <= '0;
            kb       <= '0;
            t        <= '0;
          end
        end

        S_COMPUTE: begin
          if (t == 4'd15) begin
            t <= '0;
            if (kb != nblk_m1) kb <= kb + 4'd1;
          end else begin
            t <= t + 4'd1;
          end
        end

        S_DRAIN_LAST: begin
          if (t == 4'd15) begin
            t       <= '0;
            row     <= '0;
            div_cnt <= '0;
          end else begin
            t <= t + 4'd1;
          end
        end

        S_DIVIDE: begin
          if (div_cnt == 6'd34) begin
            if (row == 2'd3) begin
              if (rg == nblk_m1) begin
                done <= 1'b1;
              end else begin
                rg  <= rg + 4'd1;
                kb  <= '0;
                t   <= '0;
              end
            end else begin
              row     <= row + 2'd1;
              div_cnt <= '0;
            end
          end else begin
            div_cnt <= div_cnt + 6'd1;
          end
        end

        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------------
  // Benchmark cycle counter.
  // ---------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) cycle_count <= 32'd0;
    else if (state == S_IDLE) cycle_count <= start ? 32'd1 : cycle_count;
    else cycle_count <= cycle_count + 32'd1;
  end

`ifdef FORMAL
  // Formal-only scaffolding (guarded, never synthesized; the initial block
  // is exempt from the no-initial-in-RTL rule for that reason). Control-only
  // per docs/uarch.md 8.3 and CLAUDE.md's formal-is-a-subset rule: none of
  // these properties reference the RAMs, NUM accumulators, score/rescale
  // arithmetic, or the divider bank.
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;

  always_comb begin
    // busy/done mutual exclusion. Guarded by f_past_valid like every other
    // property in this block: unguarded, BMC checks this at step 0 too,
    // where all registers (including state) are unconstrained free
    // variables, producing an unreachable state=S_COMPUTE && done=1
    // counterexample at step 0 that never occurs from a real reset.
    if (f_past_valid) assert (!(busy && done));
  end

  always_ff @(posedge clk) begin
    if (f_past_valid) begin
      if ($past(rst)) begin
        assert (state == S_IDLE);
        assert (busy == 1'b0);
        assert (done == 1'b0);
        assert (cycle_count == 32'd0);
      end else begin
        // done implies idle.
        if (done) assert (state == S_IDLE);
        // cycle_count monotone non-decreasing while busy.
        if ($past(busy) && busy) assert (cycle_count >= $past(cycle_count));
      end
    end
  end
`endif

endmodule
