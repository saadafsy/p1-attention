`timescale 1ns / 1ps
// attention_top: 4-row-blocked streaming attention (uarch 8.3), built from
// mac_unit, matmul_tile and online_softmax. Implements rounding sites 1
// (score conversion), 4 (numerator rescale) and 5 (output division),
// bit-identical to model/attn.py attn_fixed.
//
// Formats (uarch 2): ACT Q1.6 s8 (Q/K/V/out), SACC Q11.12 s24, SCORE Q5.10
// s16, WGT UQ1.15 u16 (w, r), DEN UQ9.15 u24 (l), NUM Q10.21 s32 (acc_num).
//
// Dataflow: query rows in groups of 4 lanes; per group, K/V blocks of 4 run
// through matmul_tile in 16-cycle blocks (S_COMPUTE) while the previous block
// drains into 4 online_softmax lanes (lane = t[1:0], key = t[3:2]).
// S_DRAIN_LAST drains the final block, then S_DIVIDE runs 16 serial
// dividers per row, 4 rows x 35 cycles (load, 33 iterate, write).
//
// PIPE_ROM: forwarded to the softmax lanes (1 = out_valid two cycles after
//   in_valid); this module adds a matching V-row stage.
// PV_SPLIT: 1 = PV rescale as three partial products (ASIC timing);
//   0 = one product for DSP48 slices.
module attention_top #(
    parameter bit PIPE_ROM = 1'b0,
    parameter bit PV_SPLIT = 1'b1
) (
    input  logic        clk,
    input  logic        rst,        // synchronous, active-high

    // Load port: byte write into the Q/K/V RAMs.
    input  logic [ 1:0] sel,        // 0=Q, 1=K, 2=V, 3=no write
    input  logic [ 9:0] addr,       // {row[5:0], col[3:0]}
    input  logic [ 7:0] wdata,      // ACT Q1.6
    input  logic        we,

    // verilator lint_off UNUSEDSIGNAL
    // n_len is a multiple of 4, so n_len[1:0] is unused.
    input  logic [ 6:0] n_len,      // multiple of 4, 4 <= n_len <= 64
    // verilator lint_on UNUSEDSIGNAL
    input  logic        start,      // pulse; accepted only when busy = 0
    output logic        busy,
    output logic        done,       // one-cycle pulse, the cycle busy falls

    input  logic [ 9:0] rd_addr,    // {row[5:0], col[3:0]}
    output logic [ 7:0] rd_data,    // ACT Q1.6, valid one cycle after rd_addr

    output logic [31:0] cycle_count
);

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

  // nblk_reg in [1,16], so the low 4 bits of nblk_reg - 1 are (nblk-1) mod 16;
  // bit 4 is unused.
  // verilator lint_off UNUSEDSIGNAL
  logic [4:0] nblk_m1_full;
  assign nblk_m1_full = nblk_reg - 5'd1;
  wire [3:0] nblk_m1 = nblk_m1_full[3:0];
  // verilator lint_on UNUSEDSIGNAL

  // Next-cycle rg/kb/t. Also drive the Q/K RAM read address one cycle early,
  // so the registered RAM output lands with zero added latency.
  logic [3:0] rg_n, kb_n, t_n;

  always_comb begin
    rg_n = rg;
    kb_n = kb;
    t_n  = t;
    unique case (state)
      S_IDLE: begin
        if (start) begin
          rg_n = '0;
          kb_n = '0;
          t_n  = '0;
        end
      end
      S_COMPUTE: begin
        if (t == 4'd15) begin
          t_n = '0;
          if (kb != nblk_m1) kb_n = kb + 4'd1;
        end else begin
          t_n = t + 4'd1;
        end
      end
      S_DRAIN_LAST: begin
        if (t == 4'd15) t_n = '0;
        else t_n = t + 4'd1;
      end
      S_DIVIDE: begin
        if (div_cnt == 6'd34 && row == 2'd3 && rg != nblk_m1) begin
          rg_n = rg + 4'd1;
          kb_n = '0;
          t_n  = '0;
        end
      end
      default: ;
    endcase
  end

  // Round-robin drain control (lane = t[1:0], key = t[3:2]), prefetched like
  // s_conv: computed from state_n/kb_n/t_n and registered, so each register
  // equals the combinational value of this cycle (FORMAL checks it below).
  // drain_blk = DRAIN_LAST ? nblk-1 : kb-1. nblk_reg only changes on an
  // accepted start, when state_n = S_COMPUTE, so nblk_m1 is next-cycle exact.
  logic       drain_en_n;
  logic [3:0] drain_blk_n;
  logic       row_start_n;

  always_comb begin
    drain_en_n  = ((state_n == S_COMPUTE) && (kb_n != 4'd0)) || (state_n == S_DRAIN_LAST);
    drain_blk_n = (state_n == S_DRAIN_LAST) ? nblk_m1 : (kb_n - 4'd1);
    row_start_n = drain_en_n && (t_n[3:2] == 2'd0) && (drain_blk_n == 4'd0);
  end

  logic [5:0] drain_v_row;     // V RAM read address {drain_blk, key}
  logic       row_start_val;   // the drained element is its row's first
  logic       lane_in_valid  [4];
  logic       lane_row_start [4];

  // Reset values are the combinational values in the reset state
  // (S_IDLE, kb = t = 0: drain_blk = 15).
  always_ff @(posedge clk) begin
    if (rst) begin
      drain_v_row   <= 6'b111100;
      row_start_val <= 1'b0;
    end else begin
      drain_v_row   <= {drain_blk_n, t_n[3:2]};
      row_start_val <= row_start_n;
    end
  end

  for (genvar gC = 0; gC < 4; gC++) begin : g_lane_ctl
    always_ff @(posedge clk) begin
      if (rst) begin
        lane_in_valid[gC]  <= 1'b0;
        lane_row_start[gC] <= 1'b0;
      end else begin
        lane_in_valid[gC]  <= drain_en_n && (t_n[1:0] == gC[1:0]);
        lane_row_start[gC] <= row_start_n && (t_n[1:0] == gC[1:0]);
      end
    end
  end

  // Block boundary: the finished block is captured into drain_buf.
  wire capture = (state == S_COMPUTE) && (t == 4'd15);

  // Storage: sync_ram instances (BRAM/SRAM inferable). Contents are not reset;
  // the FSM only reads locations written for the current n_len.
  // Q, K: column-major, word {group, col} holds 4 ACT bytes = q_flat/k_flat;
  // a load lands in byte lane row[1:0]. V: one 16-byte row per word.
  // out: written a whole row by the divider bank, read one byte at a time.
  wire [5:0] wr_row = addr[9:4];
  wire [3:0] wr_col = addr[3:0];
  wire [7:0] qk_waddr     = {addr[9:6], addr[3:0]};
  wire [1:0] qk_byte_lane = addr[5:4];

  wire we_q = we && (sel == 2'd0);
  wire we_k = we && (sel == 2'd1);
  wire we_v = we && (sel == 2'd2);

  logic [31:0] q_flat;
  logic [31:0] k_flat;

  sync_ram #(.AW(8), .DW(32)) u_qmem (
      .clk  (clk),
      .rst  (rst),
      .we   (we_q),
      .be   (4'b0001 << qk_byte_lane),
      .waddr(qk_waddr),
      .wdata({4{wdata}}),
      .raddr({rg_n, t_n}),
      .rdata(q_flat)
  );

  sync_ram #(.AW(8), .DW(32)) u_kmem (
      .clk  (clk),
      .rst  (rst),
      .we   (we_k),
      .be   (4'b0001 << qk_byte_lane),
      .waddr(qk_waddr),
      .wdata({4{wdata}}),
      .raddr({kb_n, t_n}),
      .rdata(k_flat)
  );

  // V is addressed on the in_valid cycle; the row arrives on out_valid.
  logic [127:0] v_row_reg;

  sync_ram #(.AW(6), .DW(128)) u_vmem (
      .clk  (clk),
      .rst  (rst),
      .we   (we_v),
      .be   (16'h0001 << wr_col),
      .waddr(wr_row),
      .wdata({16{wdata}}),
      .raddr(drain_v_row),
      .rdata(v_row_reg)
  );

  // PIPE_ROM = 1: one more stage to match the later out_valid. At most one
  // element enters per cycle, so a plain shift stays aligned.
  logic [127:0] v_row_pv;  // V row consumed by the PV datapath this cycle
  if (PIPE_ROM) begin : g_vrow_lat2
    logic [127:0] v_row_reg2;
    always_ff @(posedge clk) begin
      if (rst) v_row_reg2 <= '0;
      else v_row_reg2 <= v_row_reg;
    end
    assign v_row_pv = v_row_reg2;
  end else begin : g_vrow_lat1
    assign v_row_pv = v_row_reg;
  end

  // Output RAM: the byte is selected after the read with the registered
  // column, so rd_data is valid one cycle after rd_addr.
  logic [127:0] out_word_pack;
  for (genvar gp = 0; gp < 16; gp++) begin : g_out_pack
    assign out_word_pack[8*gp+:8] = out_wr_data[gp];
  end

  logic [127:0] out_rd_word;
  logic [  3:0] rd_col_q;

  sync_ram #(.AW(6), .DW(128)) u_outmem (
      .clk  (clk),
      .rst  (rst),
      .we   (out_we),
      .be   ('1),
      .waddr(out_wr_row),
      .wdata(out_word_pack),
      .raddr(rd_addr[9:4]),
      .rdata(out_rd_word)
  );

  always_ff @(posedge clk) begin
    if (rst) rd_col_q <= '0;
    else rd_col_q <= rd_addr[3:0];
  end

  assign rd_data = out_rd_word[8*rd_col_q+:8];

  // matmul_tile, fed from the prefetched Q/K RAM outputs.
  logic        tile_en;
  logic        tile_clr;
  logic [383:0] acc_flat;

  always_comb begin
    tile_en  = (state == S_COMPUTE);
    tile_clr = (state == S_COMPUTE) && (t == 4'd0);
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

  // Double buffer, captured at t == 15 before the next clr. At that edge
  // acc_flat holds only d=0..14, so drain_buf_next adds the d=15 product from
  // this cycle's q_flat/k_flat; the captured block is the exact D=16 sum.
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
    else if (capture) drain_buf <= drain_buf_next;
  end

  // Score conversion (rounding site 1, uarch 3.3): s = sat16((sacc + 8) >>> 4),
  // element index 4*lane + key_local. Prefetched one cycle so online_softmax
  // reads s from a flop: index uses t + 1 (the next drain cycle), and on the
  // capture cycle element 0 comes from drain_buf_next.
  wire [3:0]         t_inc     = t + 4'd1;
  wire [3:0]         elem_n    = {t_inc[1:0], t_inc[3:2]};
  wire signed [23:0] sacc_n    = capture ? drain_buf_next[23:0] : drain_buf[24*elem_n+:24];

  logic signed [24:0] s_wide;
  logic signed [24:0] s_shift;
  logic signed [15:0] s_conv_n;
  logic signed [15:0] s_conv;

  always_comb begin
    s_wide  = 25'(sacc_n) + 25'sd8;
    s_shift = s_wide >>> 4;
    if (s_shift > 25'sd32767) s_conv_n = 16'sd32767;
    else if (s_shift < -25'sd32768) s_conv_n = -16'sd32768;
    else s_conv_n = s_shift[15:0];
  end

  always_ff @(posedge clk) begin
    if (rst) s_conv <= '0;
    else s_conv <= s_conv_n;
  end

  // 4 online_softmax lanes (in_valid/row_start registered above).
  logic [15:0] lane_w  [4];
  logic [15:0] lane_r  [4];
  // verilator lint_off UNUSEDSIGNAL
  // Read only under FORMAL; the PV datapath uses its own per-column copy.
  logic        lane_out_valid [4];
  // verilator lint_on UNUSEDSIGNAL
  logic [23:0] lane_l  [4];
  // verilator lint_off UNUSEDSIGNAL
  // m is a debug/formal output of online_softmax; not needed here.
  logic [15:0] lane_m  [4];
  // verilator lint_on UNUSEDSIGNAL

  for (genvar gL = 0; gL < 4; gL++) begin : g_softmax
    online_softmax #(
        .PIPE_ROM(PIPE_ROM)
    ) u_sm (
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

  // NUM accumulators (rounding site 4, uarch 3.7): 4 lanes x 16 k of state,
  // updated through one shared 16-wide PV datapath. Round-robin draining
  // makes at most one lane's out_valid high per cycle.
  logic signed [31:0] acc_num [4][16];

  // Per column k: acc_next = rshr(acc_base * r, 15) + w * v[k], two stages.
  // Stage A (out_valid cycle) registers the products; stage B adds and writes.
  // Safe because a lane's next element arrives 4 cycles later. Lane 0's last
  // update is written by DRAIN_LAST t = 15, before S_DIVIDE samples row 0.
  // Each column keeps its own copy of the lane-select delay line (fanout);
  // FORMAL asserts it equals lane_out_valid.
  localparam int PvLat = 1 + int'(PIPE_ROM);

  // acc_base * r: PV_SPLIT = 1 splits r into [5:0], [11:6], [15:12] and stage
  // B sums lo + (mid << 6) + (hi << 12), exact. PV_SPLIT = 0 is one product
  // (two DSP48s). Only the low 47 bits reach the 32-bit result.
  for (genvar gK = 0; gK < 16; gK++) begin : g_pv
    // Newest entry in the low bits; the top entry is the element at out_valid.
    // keep: the 16 copies are duplicated on purpose for fanout.
    (* keep *) logic [4*PvLat-1:0] lsel_d;  // one-hot lane in flight
    (* keep *) logic [  PvLat-1:0] rs_d;  // element is its row's first
    logic [3:0] lsel;  // stage A select
    logic       rs;
    (* keep *) logic [3:0] lselb;  // stage B select (lsel one cycle later)

    always_ff @(posedge clk) begin
      if (rst) begin
        lsel_d <= '0;
        rs_d   <= '0;
        lselb  <= '0;
      end else begin
        lsel_d <= (4 * PvLat)'({lsel_d, lane_in_valid[3], lane_in_valid[2],
                                lane_in_valid[1], lane_in_valid[0]});
        rs_d   <= PvLat'({rs_d, row_start_val});
        lselb  <= lsel;
      end
    end

    logic signed [31:0] acc_sel;
    logic        [15:0] w_sel, r_sel;
    logic signed [31:0] acc_base;
    logic signed [23:0] wv_prod;
    logic signed [23:0] pva_wv;  // w * v[k], registered
    logic signed [46:0] ar_q;  // acc_base * r, from the registered terms
    logic signed [46:0] ar_rnd;

    always_comb begin
      lsel    = lsel_d[4*PvLat-1-:4];
      rs      = rs_d[PvLat-1];
      acc_sel = '0;
      w_sel   = '0;
      r_sel   = '0;
      for (int i = 0; i < 4; i++) begin  // one-hot AND-OR mux
        if (lsel[i]) begin
          acc_sel = acc_sel | acc_num[i][gK];
          w_sel   = w_sel | lane_w[i];
          r_sel   = r_sel | lane_r[i];
        end
      end
      acc_base = rs ? 32'sd0 : acc_sel;
      wv_prod  = 24'(signed'({1'b0, w_sel}) * signed'(v_row_pv[8*gK+:8]));
      // (acc*r + 2^14 + w*v * 2^15) >>> 15 == rshr(acc*r, 15) + w*v exactly.
      ar_rnd   = ar_q + (47'(pva_wv) <<< 15) + 47'sd16384;
    end

    always_ff @(posedge clk) begin
      if (rst) pva_wv <= '0;
      else if (|lsel) pva_wv <= wv_prod;
    end

    if (PV_SPLIT) begin : g_split
      logic signed [38:0] pva_lo;  // acc_base * r[5:0]
      logic signed [38:0] pva_mid;  // acc_base * r[11:6]
      logic signed [36:0] pva_hi;  // acc_base * r[15:12]
      always_ff @(posedge clk) begin
        if (rst) begin
          pva_lo  <= '0;
          pva_mid <= '0;
          pva_hi  <= '0;
        end else if (|lsel) begin
          pva_lo  <= 39'(signed'(acc_base) * signed'({1'b0, r_sel[5:0]}));
          pva_mid <= 39'(signed'(acc_base) * signed'({1'b0, r_sel[11:6]}));
          pva_hi  <= 37'(signed'(acc_base) * signed'({1'b0, r_sel[15:12]}));
        end
      end
      assign ar_q = 47'(pva_lo) + (47'(pva_mid) <<< 6) + (47'(pva_hi) <<< 12);
    end else begin : g_whole
      logic signed [46:0] pva_ar;  // acc_base * r
      always_ff @(posedge clk) begin
        if (rst) pva_ar <= '0;
        else if (|lsel) pva_ar <= 47'(signed'(acc_base) * signed'({1'b0, r_sel}));
      end
      assign ar_q = pva_ar;
    end

    // Stage B: the selected lane's accumulator takes the sum.
    for (genvar gL2 = 0; gL2 < 4; gL2++) begin : g_num_lane
      always_ff @(posedge clk) begin
        if (rst) acc_num[gL2][gK] <= '0;
        else if (lselb[gL2]) acc_num[gL2][gK] <= 32'(ar_rnd >>> 15);
      end
    end

`ifdef FORMAL
    logic f_pv_init;
    initial f_pv_init = 1'b0;
    always_ff @(posedge clk) f_pv_init <= 1'b1;
    always_comb begin
      if (f_pv_init)
        assert (lsel == {lane_out_valid[3], lane_out_valid[2],
                         lane_out_valid[1], lane_out_valid[0]});
    end
`endif
  end

  // Divider bank (uarch 3.8, rounding site 5): 16 columns, shared div_cnt/row.
  // Each column has its own copy of row to limit fanout on the B select.
  logic [1:0] row_n;

  always_comb begin
    row_n = row;
    if (state == S_DRAIN_LAST && t == 4'd15) row_n = 2'd0;
    else if (state == S_DIVIDE && div_cnt == 6'd34 && row != 2'd3) row_n = row + 2'd1;
  end

  wire [5:0] out_wr_row = {rg, row};
  logic        out_we;
  logic [7:0]  out_wr_data [16];
  assign out_we = (state == S_DIVIDE) && (div_cnt == 6'd34);

  for (genvar gD = 0; gD < 16; gD++) begin : g_div
    (* keep *) logic [1:0] row_c;  // this column's copy of row
    logic        [23:0] div_den;
    logic        [24:0] div_b;  // B = 2*den, 25-bit unsigned

    always_ff @(posedge clk) begin
      if (rst) row_c <= '0;
      else row_c <= row_n;
    end

    always_comb begin
      div_den = lane_l[row_c];
      div_b   = {div_den, 1'b0};
    end

`ifdef FORMAL
    logic f_div_init;
    initial f_div_init = 1'b0;
    always_ff @(posedge clk) f_div_init <= 1'b1;
    always_comb if (f_div_init) assert (row_c == row);
`endif

    logic signed [33:0] a_val;      // A = 2*num + den, 34-bit signed
    // verilator lint_off UNUSEDSIGNAL
    // Top bits are always 0 (|A| < 2^33; selected trial < B < 2^25); kept
    // full width so the negation/subtraction cannot truncate.
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
      a_val      = (34'(signed'(acc_num[row_c][gD])) <<< 1) + 34'(signed'({1'b0, div_den}));
      abs_a_full = a_val[33] ? (-a_val) : a_val;
      abs_a_val  = abs_a_full[32:0];
      sign_a_val = a_val[33];

      // Valid for div_cnt in [1,33]; clamped to 0 elsewhere (unused there).
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

  // FSM sequencing.
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
      rg  <= rg_n;
      kb  <= kb_n;
      t   <= t_n;
      row <= row_n;

      unique case (state)
        S_IDLE: begin
          if (start) nblk_reg <= n_len[6:2];
        end

        S_COMPUTE: ;

        S_DRAIN_LAST: begin
          if (t == 4'd15) div_cnt <= '0;
        end

        S_DIVIDE: begin
          if (div_cnt == 6'd34) begin
            if (row == 2'd3) begin
              if (rg == nblk_m1) done <= 1'b1;
            end else begin
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

  always_ff @(posedge clk) begin
    if (rst) cycle_count <= 32'd0;
    else if (state == S_IDLE) cycle_count <= start ? 32'd1 : cycle_count;
    else cycle_count <= cycle_count + 32'd1;
  end

`ifdef FORMAL
  // Control-only properties; no RAM, accumulator or divider checks.
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;

  // Start from reset: the FSM invariants below are false for arbitrary
  // initial states that reset can never produce.
  initial assume (rst);

  // Shortest run (n_len = 4) is 173 cycles; pinning n_len makes done
  // reachable within the BMC depth. Only the accepted-start value matters.
  always_comb begin
    if (state == S_IDLE && start) assume (n_len == 7'd4);
  end

  // The shared PV datapath needs one-hot-or-zero lane_out_valid.
  always_comb begin
    if (f_past_valid)
      assert ($onehot0({lane_out_valid[3], lane_out_valid[2],
                        lane_out_valid[1], lane_out_valid[0]}));
  end

  always_ff @(posedge clk) begin
    if (f_past_valid) cover (done);
  end

  // Prefetched drain control == the former combinational expressions.
  wire [1:0] f_lane      = t[1:0];
  wire [1:0] f_key_local = t[3:2];
  wire       f_drain_en  = ((state == S_COMPUTE) && (kb != 4'd0)) || (state == S_DRAIN_LAST);
  wire [3:0] f_drain_blk = (state == S_DRAIN_LAST) ? nblk_m1 : (kb - 4'd1);
  wire       f_row_start = f_drain_en && (f_key_local == 2'd0) && (f_drain_blk == 4'd0);

  always_comb begin
    if (f_past_valid) begin
      assert (drain_v_row == {f_drain_blk, f_key_local});
      assert (row_start_val == f_row_start);
    end
  end

  for (genvar fL = 0; fL < 4; fL++) begin : g_f_lane_ctl
    always_comb begin
      if (f_past_valid) begin
        assert (lane_in_valid[fL] == (f_drain_en && (f_lane == fL[1:0])));
        assert (lane_row_start[fL] == (f_row_start && (f_lane == fL[1:0])));
      end
    end
  end

  always_comb begin
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
        if (done) assert (state == S_IDLE);
        if ($past(busy) && busy) assert (cycle_count >= $past(cycle_count));
      end
    end
  end
`endif

endmodule
