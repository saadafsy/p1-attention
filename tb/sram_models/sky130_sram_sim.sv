`timescale 1ns / 1ps
// Simulation views of the two OpenRAM macros: the vendor model (*_model.v)
// behind a shim that removes its zero-delay races.
// - The model blanks dout to x with a blocking write on the rising edge, in
//   the same time step as the design flops that sample dout. The shim
//   captures the inputs on the real edge and clocks the model 1 ns later,
//   so the design samples dout before it is blanked.
// - dout1 is then valid 1 + 5 + DELAY(3) = 9 ns after the rising edge (10 ns
//   clock): later than a flop output, so a test must sample it after 9 ns.
// - A write and a read of one address in the same cycle is undefined in the
//   macro (the model's result depends on process order). The shim returns
//   POISON for that read and counts it in n_collide, so a test that uses
//   the data fails.
// verilator lint_off DECLFILENAME
// verilator lint_off PROCASSINIT
module sky130_sram_sim_shim #(
    parameter int DW = 64,
    localparam int NM = DW / 8
) (
    input  logic          clk0,
    input  logic          csb0,
    input  logic          web0,
    input  logic [NM-1:0] wmask0,
    input  logic [   7:0] addr0,
    input  logic [DW-1:0] din0,
    output logic [DW-1:0] dout0,
    input  logic          clk1,
    input  logic          csb1,
    input  logic [   7:0] addr1,
    output logic [DW-1:0] dout1
);

  localparam logic [DW-1:0] POISON = {NM{8'hA5}};

  logic          csb0_q = 1'b1, web0_q = 1'b1, csb1_q = 1'b1;
  logic [NM-1:0] wmask0_q = '0;
  logic [   7:0] addr0_q = '0, addr1_q = '0;
  logic [DW-1:0] din0_q = '0;
  logic          collide = 1'b0;
  int unsigned   n_collide = 0;

  always @(posedge clk0) begin
    csb0_q   <= csb0;
    web0_q   <= web0;
    wmask0_q <= wmask0;
    addr0_q  <= addr0;
    din0_q   <= din0;
  end

  always @(posedge clk1) begin
    csb1_q  <= csb1;
    addr1_q <= addr1;
    collide <= !csb0 && !web0 && (|wmask0) && !csb1 && (addr0 == addr1);
    if (!csb0 && !web0 && (|wmask0) && !csb1 && (addr0 == addr1)) n_collide <= n_collide + 1;
  end

  logic clk0_d, clk1_d;
  assign #1 clk0_d = clk0;
  assign #1 clk1_d = clk1;

  logic [DW-1:0] dout1_m;
  assign dout1 = collide ? POISON : dout1_m;

  if (DW == 64) begin : g_64
    sky130_sram_1rw1r_64x256_8_model u_model (
        .clk0(clk0_d), .csb0(csb0_q), .web0(web0_q), .wmask0(wmask0_q),
        .addr0(addr0_q), .din0(din0_q), .dout0(dout0),
        .clk1(clk1_d), .csb1(csb1_q), .addr1(addr1_q), .dout1(dout1_m)
    );
  end else begin : g_128
    sky130_sram_1rw1r_128x256_8_model u_model (
        .clk0(clk0_d), .csb0(csb0_q), .web0(web0_q), .wmask0(wmask0_q),
        .addr0(addr0_q), .din0(din0_q), .dout0(dout0),
        .clk1(clk1_d), .csb1(csb1_q), .addr1(addr1_q), .dout1(dout1_m)
    );
  end

  final if (n_collide != 0) $display("%m: %0d same-address read-during-write cycles", n_collide);

endmodule

// verilog_lint: waive module-filename
module sky130_sram_1rw1r_64x256_8 (
    input  logic        clk0,
    input  logic        csb0,
    input  logic        web0,
    input  logic [ 7:0] wmask0,
    input  logic [ 7:0] addr0,
    input  logic [63:0] din0,
    output logic [63:0] dout0,
    input  logic        clk1,
    input  logic        csb1,
    input  logic [ 7:0] addr1,
    output logic [63:0] dout1
);
  sky130_sram_sim_shim #(.DW(64)) u_shim (.*);
endmodule

// verilog_lint: waive module-filename
module sky130_sram_1rw1r_128x256_8 (
    input  logic         clk0,
    input  logic         csb0,
    input  logic         web0,
    input  logic [ 15:0] wmask0,
    input  logic [  7:0] addr0,
    input  logic [127:0] din0,
    output logic [127:0] dout0,
    input  logic         clk1,
    input  logic         csb1,
    input  logic [  7:0] addr1,
    output logic [127:0] dout1
);
  sky130_sram_sim_shim #(.DW(128)) u_shim (.*);
endmodule
