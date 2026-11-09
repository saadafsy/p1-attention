`timescale 1ns / 1ps
// sync_ram_sky130: rtl/sync_ram.sv on an OpenRAM sky130 1rw1r macro
// (docs/uarch.md 8.5). Port 0 (rw) only writes; port 1 (r) reads every cycle.
// DW <= 64 uses sky130_sram_1rw1r_64x256_8, else sky130_sram_1rw1r_128x256_8.
// Unused data bits and upper address bits are tied to 0, unused mask bits off.
// Same as sync_ram: rdata = mem[raddr] one cycle later, byte-enabled writes,
// rdata = 0 on the cycle after a reset cycle (rd_ok gates the macro output,
// which has no reset).
// Not the same: reading the address that is written in the same cycle gives
// undefined data (no OpenRAM guarantee; sync_ram gives the old data). The
// caller must not use that read; attention_top never does (uarch 8.5).
// The macro drives dout from the falling clock edge (liberty falling_edge
// arc), so rdata has about half a cycle to reach the next flop.
module sync_ram_sky130 #(
    parameter int AW = 8,  // address bits, at most 8
    parameter int DW = 32,  // data bits, a multiple of 8, at most 128
    localparam int NB = DW / 8
) (
    input  logic          clk,
    input  logic          rst,    // synchronous, clears rdata
    input  logic          we,
    input  logic [NB-1:0] be,
    input  logic [AW-1:0] waddr,
    input  logic [DW-1:0] wdata,
    input  logic [AW-1:0] raddr,
    output logic [DW-1:0] rdata
);

  localparam int MW = (DW <= 64) ? 64 : 128;  // macro word width
  localparam int MB = MW / 8;

  if (AW > 8 || DW > 128 || DW % 8 != 0) begin : g_bad_shape
    $error("sync_ram_sky130: unsupported AW=%0d DW=%0d", AW, DW);
  end

  wire          wr_en = we && (|be);  // no macro access for an all-zero mask
  wire [   7:0] addr0 = 8'(waddr);
  wire [   7:0] addr1 = 8'(raddr);
  wire [MW-1:0] din0 = MW'(wdata);
  wire [MB-1:0] wmask0 = MB'(be);

  // verilator lint_off UNUSEDSIGNAL
  logic [MW-1:0] dout0;  // port 0 never reads
  logic [MW-1:0] dout1;  // bits above DW are the tied-off columns
  // verilator lint_on UNUSEDSIGNAL

  if (MW == 64) begin : g_m64
    sky130_sram_1rw1r_64x256_8 u_sram (
        .clk0  (clk),
        .csb0  (!wr_en),
        .web0  (1'b0),
        .wmask0(wmask0),
        .addr0 (addr0),
        .din0  (din0),
        .dout0 (dout0),
        .clk1  (clk),
        .csb1  (1'b0),
        .addr1 (addr1),
        .dout1 (dout1)
    );
  end else begin : g_m128
    sky130_sram_1rw1r_128x256_8 u_sram (
        .clk0  (clk),
        .csb0  (!wr_en),
        .web0  (1'b0),
        .wmask0(wmask0),
        .addr0 (addr0),
        .din0  (din0),
        .dout0 (dout0),
        .clk1  (clk),
        .csb1  (1'b0),
        .addr1 (addr1),
        .dout1 (dout1)
    );
  end

  // rd_ok = 0 on the cycle after a reset cycle, as sync_ram's cleared rdata.
  logic rd_ok;
  always_ff @(posedge clk) begin
    if (rst) rd_ok <= 1'b0;
    else rd_ok <= 1'b1;
  end

  assign rdata = rd_ok ? dout1[DW-1:0] : '0;

endmodule
