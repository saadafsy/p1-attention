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
// Storage: Q, K, V and out are rtl/sync_ram.sv instances (one byte-enabled
// write port, one registered read port: block RAM on an FPGA, SRAM macros
// in an ASIC). Q and K are column-major, 4 ACT bytes per word, so one read
// per cycle is exactly q_flat / k_flat; the read address is prefetched from
// the FSM's next-state values (rg_n / kb_n / t_n) so the registered output
// lands the cycle it is used. V is one 16-byte row per word, addressed on
// the in_valid cycle so the row arrives on the out_valid cycle. RAM contents
// are not reset (that blocks BRAM inference); the FSM never reads a location
// not written for the current n_len.
//
// Timing structure (docs/uarch.md 8.4): the softmax score is prefetched into
// a register, the PV datapath is two pipeline stages, and the lane / row
// selects are replicated per column. None of it changes the cycle formula.
//
// Parameters:
//   PIPE_ROM: forwarded to the four online_softmax lanes. 1 = registered-ROM
//     lanes (out_valid two cycles after in_valid); this module absorbs the
//     extra cycle (one more V-row stage and a longer select delay line).
//   PV_SPLIT: 1 = PV rescale multiply as three partial products (standard-
//     cell timing); 0 = one product, for DSP48 slices (fpga/attn_uart_top.sv).
module attention_top #(
    parameter bit PIPE_ROM = 1'b0,
    parameter bit PV_SPLIT = 1'b1  // 1: split PV multiply (ASIC timing); 0: one product (FPGA)
) (
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
  // Main FSM state and counters (declared first: the read-address prefetch
  // logic just below needs rg/kb/t and nblk_m1).
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
  // Read-address prefetch (docs/uarch.md 8.3): rg_n/kb_n/t_n are the exact
  // next-cycle values of rg/kb/t (the same case structure as the sequential
  // update further below, lifted out combinationally so they can ALSO
  // drive the Q/K RAM read address one cycle before it is needed).
  // Presenting the NEXT address to a synchronous-read RAM on this cycle
  // makes the RAM's own registered output land, on the next cycle, exactly
  // the value a combinational read of the CURRENT (rg, kb, t) would have
  // given -- zero added latency, no stall, cycle_count formula unchanged.
  // ---------------------------------------------------------------------
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

  // ---------------------------------------------------------------------
  // Drain / round-robin addressing (computed ahead of the memory section:
  // drain_v_row is the V RAM's read address, presented one cycle before the
  // out_valid cycle that consumes it -- see the V RAM block below).
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

  logic       row_start_val;
  always_comb row_start_val = drain_en && (key_local == 2'd0) && (drain_blk == 4'd0);

  // Block boundary: the finished block is captured into drain_buf.
  wire capture = (state == S_COMPUTE) && (t == 4'd15);

  // ---------------------------------------------------------------------
  // Internal storage (docs/uarch.md 8.3): Block-RAM-inferable synchronous
  // memories, one write port + one synchronous read port per memory, NOT
  // register arrays. See the module header comment for the geometry
  // rationale. Memory CONTENTS carry no reset (load-before-use protocol).
  // ---------------------------------------------------------------------

  // Q, K: column-major, 4 ACT bytes per word, word address {group, col}
  // (group = rg for Q, kb for K). One word is exactly q_flat / k_flat (lane
  // i in bits [8*i+:8], uarch 8.1). A load-port write lands in byte lane
  // row[1:0], the row's position within its group of 4.
  // V: row-major, one 16-byte V row per word. out: row-major, written a
  // whole row at a time by the divider bank, read back one byte at a time.
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

  // The V read address is drain_v_row, presented on the in_valid cycle, so
  // the RAM's 1-cycle read latency lands the row on the out_valid cycle.
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

  // PIPE_ROM = 1: one more stage so the V row still lands on the (now two
  // cycles later) out_valid cycle. Elements enter at most one per cycle
  // across all lanes, so a plain per-cycle shift keeps every element's row
  // aligned with its own out_valid.
  logic [127:0] v_row_pv;  // the V row the PV datapath consumes this cycle
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

  // out: written a whole row on out_we (driven by the divider bank further
  // below). Read: the RAM registers the addressed row, and the byte is
  // selected after it with the registered column, so rd_data is valid one
  // cycle after rd_addr exactly as before.
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

  // ---------------------------------------------------------------------
  // matmul_tile feed (S_COMPUTE only). q_flat/k_flat are now the Q/K RAMs'
  // own registered read outputs (prefetched above), bit-identical every
  // cycle to the old combinational q_mem/k_mem reads (see header comment).
  // ---------------------------------------------------------------------
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
    else if (capture) drain_buf <= drain_buf_next;
  end

  // Score conversion (rounding site 1, uarch.md 3.3), one element per
  // cycle: s = sat16((sacc + 8) >>> 4) for element (lane, key_local), at
  // drain_buf index 4*lane + key_local. It is PREFETCHED: each cycle
  // converts the element the NEXT cycle drains into a register, so
  // online_softmax gets s straight from a flop. In every cycle that is
  // followed by a drain cycle (S_COMPUTE or S_DRAIN_LAST) the next t is
  // t + 1 mod 16, so the index uses t + 1 rather than the FSM's t_n (in
  // other cycles the prefetched value is never consumed). On the capture
  // cycle (S_COMPUTE, t == 15) the next element is index 0 of the block
  // being captured, read from drain_buf_next. Every other cycle drain_buf
  // does not change, so the prefetched value equals what a direct read
  // would give; latency and the cycle formula are unchanged.
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

  // ---------------------------------------------------------------------
  // 4 online_softmax lanes.
  // ---------------------------------------------------------------------
  logic        lane_in_valid  [4];
  logic        lane_row_start [4];
  logic [15:0] lane_w  [4];
  logic [15:0] lane_r  [4];
  // verilator lint_off UNUSEDSIGNAL
  // lane_out_valid is read only by the FORMAL block: the PV datapath uses
  // its own per-column copy of the same delay line (g_pv below).
  logic        lane_out_valid [4];
  // verilator lint_on UNUSEDSIGNAL
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

  // ---------------------------------------------------------------------
  // NUM accumulators (rounding site 4, uarch.md 3.7/6.1): 4 lanes x 16 k of
  // STATE, updated through ONE shared 16-wide PV datapath (uarch.md 8.3:
  // "instantiated once and driven by whichever lane's out_valid is
  // currently high"). Round-robin draining guarantees at most one lane's
  // out_valid per cycle, so a lane select + operand mux in front of a
  // single bank of 16 rescale-multiply-add columns is exact.
  //
  // Rewritten 2026-09-18 (review finding F001/F007): the previous version
  // put the full ar_full/wv_prod arithmetic inside the per-(lane, k)
  // generate loops, elaborating 64 acc*r and 64 w*v multipliers although
  // only 16 of each could ever be active; the spec, the benchmark's
  // "16 PV" resource count and the area rationale all described the
  // shared bank. The arithmetic per column is unchanged bit for bit.
  // ---------------------------------------------------------------------
  logic signed [31:0] acc_num [4][16];

  // The one shared 16-wide PV datapath, two pipeline stages. Per column k:
  //   acc_next = rshr(acc_base * r, 15) + w * v[k]
  // Stage A (the out_valid cycle) forms both products and registers them;
  // stage B adds and writes the lane's accumulator one cycle later. This is
  // safe because a lane's next element arrives 4 cycles after the previous
  // one (round-robin drain), so stage A never reads an accumulator stage B
  // still owes a write to. The last update of a group (lane 0's final
  // element) still lands before S_DIVIDE reads acc_num[0]: drained at
  // DRAIN_LAST t = 12, out_valid at t = 13 + PIPE_ROM, written at the edge
  // after t = 14 + PIPE_ROM <= 15, and the divider samples row 0 in the
  // first S_DIVIDE cycle (t = 16). The cycle formula is unchanged.
  //
  // Lane select: the lane whose out_valid is high is the lane that was
  // drained 1 + PIPE_ROM cycles earlier, so each column keeps its OWN copy
  // of that delay line (lane_in_valid and the row-start flag, shifted
  // 1 + PIPE_ROM times) instead of all 16 columns decoding the four
  // lane_out_valid flops. Same values (the FORMAL block asserts the copy
  // equals lane_out_valid), but each select flop drives one column, not 551
  // pins, and the stage-B lane register is per column too.
  localparam int PvLat = 1 + int'(PIPE_ROM);

  // acc_base * r in stage A:
  //   PV_SPLIT = 1 (ASIC, default): three partial products acc * r[5:0],
  //     acc * r[11:6], acc * r[15:12], each a shallow multiplier; stage B
  //     adds them (acc * r = lo + (mid << 6) + (hi << 12), exact).
  //   PV_SPLIT = 0 (FPGA): one product, which maps onto two DSP48 slices
  //     (splitting would triple the DSP count past what a Basys 3 has).
  // Only the low 47 bits of the product reach the 32-bit result.
  for (genvar gK = 0; gK < 16; gK++) begin : g_pv
    // Delay lines, newest entry in the low bits: the top nibble / top bit is
    // the element whose out_valid is high this cycle. keep: the 16 copies
    // are identical on purpose (fanout), so synthesis must not merge them.
    (* keep *) logic [4*PvLat-1:0] lsel_d;  // one-hot lane in flight
    (* keep *) logic [  PvLat-1:0] rs_d;  // ... and whether it is its row's first element
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
    logic signed [46:0] ar_q;  // the registered product terms, summed (stage B)
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
      // One multi-operand sum: (acc*r + 2^14 + w*v * 2^15) >>> 15 equals
      // rshr(acc*r, 15) + w*v exactly (w*v * 2^15 is a multiple of 2^15).
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
    // The local select copy is exactly lane_out_valid (checked from the
    // first post-reset cycle on).
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

  // ---------------------------------------------------------------------
  // Divider bank (uarch.md 3.8, rounding site 5): 16-wide, shared control
  // (div_cnt, row), one instance per k. B (= 2*den) is the same for every
  // column of a row; each column selects it with its own copy of row (see
  // row_c below) so the row register does not fan out to every operand mux.
  // ---------------------------------------------------------------------
  logic [1:0] row_n;  // next row (the FSM register and the per-column copies)

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
    (* keep *) logic [1:0] row_c;  // this column's copy of row (identical by construction)
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
      a_val      = (34'(signed'(acc_num[row_c][gD])) <<< 1) + 34'(signed'({1'b0, div_den}));
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
      // rg/kb/t always take their prefetched next value (rg_n/kb_n/t_n
      // above), which already encodes exactly the same hold-or-update
      // logic the original per-state case arms implemented (see the
      // comment on the rg_n/kb_n/t_n block); this is also what makes the
      // Q/K RAM read address a valid one-cycle-early prefetch.
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
              // else: rg/kb/t already advanced above via rg_n/kb_n/t_n.
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
  // per docs/uarch.md 8.3 and docs/design_rules.md's formal-is-a-subset rule: none of
  // these properties reference the RAMs, NUM accumulators, score/rescale
  // arithmetic, or the divider bank.
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;

  // Formal-only reset constraint (standard idiom; exempt from the
  // no-initial-in-RTL rule along with the rest of this block). Without it,
  // BMC's `anyinit` starting state is a fully free/unconstrained variable
  // assignment (state, busy, done, cycle_count all arbitrary), so an FSM
  // STATE INVARIANT like "done implies idle" can be falsified at step 0/1
  // by a garbage initial state that a real reset can never produce (e.g.
  // done=1 with state != S_IDLE, never reachable from state <= S_IDLE at
  // reset). Guarding a property with f_past_valid only delays which step
  // it is checked at; it does not constrain what the state itself can be,
  // so it cannot fix this class of counterexample. `initial assume (rst)`
  // scopes the BMC trace space to reset-reachable traces, the honest
  // bounded claim for these FSM state invariants. The pure TRANSITION
  // properties in mac_unit.sv/online_softmax.sv (this-cycle-output as a
  // function of last-cycle-inputs, no reference to "the state must be
  // X") do not need this: they are true for any starting state by
  // construction, so they are proven unconditionally, not just from reset.
  initial assume (rst);

  // Formal-only input constraint (2026-09-18, review finding F013): the
  // shortest legal run is n_len = 4 (nblk = 1, 173 cycles), so a BMC depth
  // that cannot reach that point proves nothing about done or completion.
  // Pinning n_len to 4 on the accepted start makes done reachable at
  // depth >= 175 (formal/attention_top.sby task `prove`), and the `cover`
  // task proves the property is not vacuous. Only the value sampled on the
  // accepted-start cycle matters (nblk_reg is latched there).
  always_comb begin
    if (state == S_IDLE && start) assume (n_len == 7'd4);
  end

  // The shared PV datapath (above) relies on the round-robin drain making
  // lane_out_valid one-hot-or-zero on every cycle.
  always_comb begin
    if (f_past_valid)
      assert ($onehot0({lane_out_valid[3], lane_out_valid[2],
                        lane_out_valid[1], lane_out_valid[0]}));
  end

  // Reachability witness for the done-based properties (sby `cover` task).
  always_ff @(posedge clk) begin
    if (f_past_valid) cover (done);
  end

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
