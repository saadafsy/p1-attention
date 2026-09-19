`timescale 1ns / 1ps
// exp_lut_2p: the exp() LUT as a two-read-port, registered-output ROM
// (docs/uarch.md 8.2.1, added 2026-09-19). One instance serves one
// online_softmax lane in the PIPE_ROM = 1 configuration: port A looks up
// the element weight w, port B the rescale factor r, both registered on the
// edge that accepts the element (en = in_valid), which is exactly the
// w_p / r_p stage-1 register pair the pipelined variant used to hold inline.
//
// Contents: the generated case function in rtl/exp_lut.svh (emitted only by
// model/attn.py, sha256-pinned through model/exp_lut.hex). Same single
// source as before; this module only moves the two lookups behind a
// registered read so that:
//   - the portable flow (verilator, yosys, sby) sees a plain registered
//     case-ROM, no initial block, no memory file (project RTL rule);
//   - an FPGA flow can swap in fpga/exp_lut_2p_xilinx.sv (same ports, an
//     XPM dual-port ROM initialized from fpga/exp_lut.mem) with
//     `define XILINX_FPGA, mapping each lane's two lookups onto one true
//     dual-port block RAM instead of 2 KB of LUT-mux logic on the critical
//     path (target-scores change 6). The selection lives in
//     online_softmax.sv; this file is the reference implementation.
//
// Latency: 1 cycle (READ_LATENCY 1 in the XPM twin). Reset: outputs to 0,
// matching the reset value of the registers it replaces.
module exp_lut_2p (
    input  logic        clk,
    input  logic        rst,     // synchronous, active-high
    input  logic        en,      // accept addr_a/addr_b this cycle
    input  logic [ 9:0] addr_a,  // w index
    input  logic [ 9:0] addr_b,  // r index
    output logic [15:0] dout_a,  // lut[addr_a], registered
    output logic [15:0] dout_b   // lut[addr_b], registered
);

  `include "rtl/exp_lut.svh"

  always_ff @(posedge clk) begin
    if (rst) begin
      dout_a <= 16'd0;
      dout_b <= 16'd0;
    end else if (en) begin
      dout_a <= exp_lut_rom(addr_a);
      dout_b <= exp_lut_rom(addr_b);
    end
  end

endmodule
