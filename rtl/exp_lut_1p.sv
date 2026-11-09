`timescale 1ns / 1ps
// exp_lut_1p: the generated exp() LUT (rtl/exp_lut.svh) behind one
// registered read port, for online_softmax with PIPE_ROM = 1. XILINX_FPGA
// builds use the equivalent fpga/exp_lut_1p_xilinx.sv.
module exp_lut_1p (
    input  logic        clk,
    input  logic        rst,   // synchronous, active-high; output resets to 0
    input  logic        en,    // register lut[addr] this cycle
    input  logic [ 9:0] addr,
    output logic [15:0] dout   // lut[addr], one cycle after en
);

  `include "rtl/exp_lut.svh"

  always_ff @(posedge clk) begin
    if (rst) dout <= 16'd0;
    else if (en) dout <= exp_lut_rom(addr);
  end

endmodule
