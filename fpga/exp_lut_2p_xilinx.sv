`timescale 1ns / 1ps
// exp_lut_2p_xilinx: FPGA twin of rtl/exp_lut_2p.sv (added 2026-09-19,
// target-scores change 6). Same ports and the same 1-cycle registered-read
// contract, implemented with the Xilinx XPM dual-port ROM (xpm_memory_dprom)
// so each online_softmax lane's two lookups map onto ONE true dual-port
// block RAM (1024 x 16 = one RAMB18) instead of 2 KB of LUT-mux logic on
// the critical path. Selected with `define XILINX_FPGA (fpga/ builds only);
// the portable flows never see this file.
//
// Contents: fpga/exp_lut.mem, the SAME table as model/exp_lut.hex (one
// 4-digit hex word per line is exactly the XPM .mem format); model/
// crosscheck.py verifies the two files byte-identical and sha256-pinned, so
// the single-source rule holds. Add fpga/exp_lut.mem as a design source in
// Vivado (it is found by name through MEMORY_INIT_FILE).
//
// XPM memory init is the documented exemption to "no initial blocks": the
// initialization happens in the bitstream, there is no initial block in
// this file. The regce inputs are tied high (no output-register bypass),
// the read-latency-1 output register is the same stage exp_lut_2p has, and
// rst clears both output registers to 0 like the portable module.
//
// STATUS: never synthesized (no Vivado where this was written). The Vivado
// gate (fpga/scripts/synth.tcl) must confirm 4 RAMB18 for the four lanes
// and zero distributed-ROM implementations of these memories before any
// resource claim is made; see docs/phase6_fpga_guide.md.
module exp_lut_2p_xilinx (
    input  logic        clk,
    input  logic        rst,
    input  logic        en,
    input  logic [ 9:0] addr_a,
    input  logic [ 9:0] addr_b,
    output logic [15:0] dout_a,
    output logic [15:0] dout_b
);

  // verilator lint_off UNUSEDSIGNAL
  logic sbiterra, dbiterra, sbiterrb, dbiterrb;  // ECC status, unused (ECC off)
  // verilator lint_on UNUSEDSIGNAL

  xpm_memory_dprom #(
      .ADDR_WIDTH_A       (10),
      .ADDR_WIDTH_B       (10),
      .AUTO_SLEEP_TIME    (0),
      .CASCADE_HEIGHT     (0),
      .CLOCKING_MODE      ("common_clock"),
      .ECC_MODE           ("no_ecc"),
      .MEMORY_INIT_FILE   ("exp_lut.mem"),
      .MEMORY_INIT_PARAM  (""),
      .MEMORY_OPTIMIZATION("true"),
      .MEMORY_PRIMITIVE   ("block"),
      .MEMORY_SIZE        (1024 * 16),
      .MESSAGE_CONTROL    (0),
      .READ_DATA_WIDTH_A  (16),
      .READ_DATA_WIDTH_B  (16),
      .READ_LATENCY_A     (1),
      .READ_LATENCY_B     (1),
      .READ_RESET_VALUE_A ("0"),
      .READ_RESET_VALUE_B ("0"),
      .RST_MODE_A         ("SYNC"),
      .RST_MODE_B         ("SYNC"),
      .SIM_ASSERT_CHK     (0),
      .USE_MEM_INIT       (1),
      .USE_MEM_INIT_MMI   (0),
      .WAKEUP_TIME        ("disable_sleep")
  ) u_rom (
      .clka           (clk),
      .rsta           (rst),
      .ena            (en),
      .regcea         (1'b1),
      .addra          (addr_a),
      .douta          (dout_a),
      .sbiterra       (sbiterra),
      .dbiterra       (dbiterra),
      .injectsbiterra (1'b0),
      .injectdbiterra (1'b0),
      .clkb           (clk),
      .rstb           (rst),
      .enb            (en),
      .regceb         (1'b1),
      .addrb          (addr_b),
      .doutb          (dout_b),
      .sbiterrb       (sbiterrb),
      .dbiterrb       (dbiterrb),
      .injectsbiterrb (1'b0),
      .injectdbiterrb (1'b0),
      .sleep          (1'b0)
  );

endmodule
