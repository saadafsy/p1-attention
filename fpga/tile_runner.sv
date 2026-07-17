`timescale 1ns / 1ps
// tile_runner: Phase 6 first-bring-up helper (docs/phase6_fpga_guide.md 6.1
// and 6.3.5). On a go edge it plays one 16-cycle constant Q/K stream into
// matmul_tile (rtl/matmul_tile.sv, UNMODIFIED) with clr on the first cycle
// (the 8.1 contract: clr=1,en=1 starts a new tile, no dead cycle), then
// parks in R_DONE with the accumulators readable in place. On the board,
// VIO drives go/clr (levels; go is rising-edge detected here so a GUI
// toggle runs exactly once) and ILA probes done + acc_flat.
//
// Stimulus (ACT Q1.6 codes, chosen hand-checkable, one row negative):
//   Q row i, constant over d:  +1, +2, +3, -4   (q_flat = 0xFC030201)
//   K row j at element d:      (j+1)*(d+1), d = 0..15 (case ROM below)
//
// Expected accumulators, from the mac semantics of docs/uarch.md 8.1/3.2
// (acc(i,j) = exact sum of code products, SACC Q11.12, value = code/4096):
//   acc_code(i,j) = sum_{d=0..15} q_i * (j+1)*(d+1) = q_i * (j+1) * 136
//   (sum of 1..16 = 136). Element (i,j) sits at acc_flat[24*(4*i+j) +: 24]:
//
//   | Q row i (code) |   j=0    |   j=1    |   j=2    |   j=3    |
//   |----------------|----------|----------|----------|----------|
//   | 0 (+1)         |  136     |  272     |  408     |  544     |
//   |                | 0x000088 | 0x000110 | 0x000198 | 0x000220 |
//   | 1 (+2)         |  272     |  544     |  816     | 1088     |
//   |                | 0x000110 | 0x000220 | 0x000330 | 0x000440 |
//   | 2 (+3)         |  408     |  816     | 1224     | 1632     |
//   |                | 0x000198 | 0x000330 | 0x0004C8 | 0x000660 |
//   | 3 (-4)         | -544     | -1088    | -1632    | -2176    |
//   |                | 0xFFFDE0 | 0xFFFBC0 | 0xFFF9A0 | 0xFFF780 |
//
// FSM: R_IDLE (wait go edge) -> R_RUN (d = 0..15, en=1, clr at d==0) ->
// R_DONE (done=1, acc stable; go edge reruns, clr clears via the tile's
// own clr=1,en=0 contract and returns to R_IDLE).
module tile_runner (
    input  logic         clk,
    input  logic         rst,      // synchronous, active-high
    input  logic         go,       // VIO level; rising-edge detected inside
    input  logic         clr,      // VIO level; honored in R_IDLE/R_DONE only
    output logic         done,     // high once playback finished, acc stable
    output logic [383:0] acc_flat  // 16 SACC Q11.12 (packing: uarch.md 8.1)
);

  typedef enum logic [1:0] {
    R_IDLE,
    R_RUN,
    R_DONE
  } state_e;

  state_e state;
  logic [3:0] d;
  logic go_d;

  wire go_rise = go & ~go_d;

  assign done = (state == R_DONE);

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= R_IDLE;
      d     <= '0;
      go_d  <= 1'b0;
    end else begin
      go_d <= go;
      unique case (state)
        R_IDLE: begin
          if (go_rise) begin
            state <= R_RUN;
            d     <= '0;
          end
        end
        R_RUN: begin
          d <= d + 4'd1;  // wraps to 0 with the transition below; unused outside R_RUN
          if (d == 4'd15) state <= R_DONE;
        end
        R_DONE: begin
          if (clr) state <= R_IDLE;
          else if (go_rise) begin
            state <= R_RUN;
            d     <= '0;
          end
        end
        default: state <= R_IDLE;
      endcase
    end
  end

  // Tile control (all always_comb outputs assigned on all paths).
  logic tile_en, tile_clr;
  always_comb begin
    tile_en  = (state == R_RUN);
    // In R_RUN: fresh-tile clr at d==0. Outside R_RUN: clr=1,en=0 zeroes
    // the accumulators (8.1 contract) when the VIO clr level is set.
    tile_clr = ((state == R_RUN) && (d == 4'd0)) || ((state != R_RUN) && clr);
  end

  // Stimulus. Q lanes are constant codes {+1, +2, +3, -4} (lane i at bits
  // [8*i +: 8], uarch.md 8.1 packing). K lane j at cycle d is (j+1)*(d+1),
  // stored as a literal 16-entry ROM so nothing is computed in fabric.
  logic [31:0] q_flat, k_flat;

  assign q_flat = 32'hFC030201;

  always_comb begin
    unique case (d)
      4'd0:    k_flat = 32'h04030201;  // lanes 4,3,2,1  (d+1 = 1)
      4'd1:    k_flat = 32'h08060402;
      4'd2:    k_flat = 32'h0C090603;
      4'd3:    k_flat = 32'h100C0804;
      4'd4:    k_flat = 32'h140F0A05;
      4'd5:    k_flat = 32'h18120C06;
      4'd6:    k_flat = 32'h1C150E07;
      4'd7:    k_flat = 32'h20181008;
      4'd8:    k_flat = 32'h241B1209;
      4'd9:    k_flat = 32'h281E140A;
      4'd10:   k_flat = 32'h2C21160B;
      4'd11:   k_flat = 32'h3024180C;
      4'd12:   k_flat = 32'h34271A0D;
      4'd13:   k_flat = 32'h382A1C0E;
      4'd14:   k_flat = 32'h3C2D1E0F;
      4'd15:   k_flat = 32'h40302010;  // lanes 64,48,32,16 (d+1 = 16)
      default: k_flat = 32'h00000000;
    endcase
  end

  matmul_tile u_tile (
      .clk     (clk),
      .rst     (rst),
      .en      (tile_en),
      .clr     (tile_clr),
      .q_flat  (q_flat),
      .k_flat  (k_flat),
      .acc_flat(acc_flat)
  );

endmodule
