`timescale 1ns / 1ps
// exp_lut_1p_xilinx: block-RAM twin of rtl/exp_lut_1p.sv for the Artix-7
// build (selected by `define XILINX_FPGA in online_softmax.sv). An XPM
// single-port ROM, 1024 x 16 = one RAMB18 per lane, initialized from
// fpga/exp_lut.mem (byte-identical to model/exp_lut.hex, checked by
// model/crosscheck.py). Read latency 1, synchronous reset to 0, same as the
// portable module.
module exp_lut_1p_xilinx (
    input  logic        clk,
    input  logic        rst,
    input  logic        en,
    input  logic [ 9:0] addr,
    output logic [15:0] dout
);

  // verilator lint_off UNUSEDSIGNAL
  logic sbiterra, dbiterra;  // ECC status, unused (ECC off)
  // verilator lint_on UNUSEDSIGNAL

  xpm_memory_sprom #(
      .ADDR_WIDTH_A       (10),
      .AUTO_SLEEP_TIME    (0),
      .CASCADE_HEIGHT     (0),
      .ECC_MODE           ("no_ecc"),
      .MEMORY_INIT_FILE   ("exp_lut.mem"),
      .MEMORY_INIT_PARAM  (""),
      .MEMORY_OPTIMIZATION("true"),
      .MEMORY_PRIMITIVE   ("block"),
      .MEMORY_SIZE        (1024 * 16),
      .MESSAGE_CONTROL    (0),
      .READ_DATA_WIDTH_A  (16),
      .READ_LATENCY_A     (1),
      .READ_RESET_VALUE_A ("0"),
      .RST_MODE_A         ("SYNC"),
      .SIM_ASSERT_CHK     (0),
      .USE_MEM_INIT       (1),
      .USE_MEM_INIT_MMI   (0),
      .WAKEUP_TIME        ("disable_sleep")
  ) u_rom (
      .clka          (clk),
      .rsta          (rst),
      .ena           (en),
      .regcea        (1'b1),
      .addra         (addr),
      .douta         (dout),
      .sbiterra      (sbiterra),
      .dbiterra      (dbiterra),
      .injectsbiterra(1'b0),
      .injectdbiterra(1'b0),
      .sleep         (1'b0)
  );

endmodule
