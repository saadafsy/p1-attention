`timescale 1ns / 1ps
// uart_tx: 8N1 serial transmitter (Phase 6 bring-up kit; normative physical
// layer spec: docs/phase6_fpga_guide.md 6.3.3).
//
// Frame: 1 start (low), 8 data bits LSB first, 1 stop (high). Pacing:
// ClksPerBit = CLK_HZ / BAUD clocks per bit (868 at the defaults).
//
// Interface: valid/ready. ready is high when idle; a byte is accepted on
// valid AND ready and takes 10 bit times (~86.8 us at 115200). tx is wired
// to the low bit of the 10-bit {stop, data, start} shift register, which
// shifts in 1s, so the line is registered, glitch-free, and idles high.
module uart_tx #(
    parameter int unsigned CLK_HZ = 100_000_000,
    parameter int unsigned BAUD   = 115_200
) (
    input  logic       clk,
    input  logic       rst,    // synchronous, active-high
    input  logic [7:0] data,   // byte to send
    input  logic       valid,  // request; accepted on valid && ready
    output logic       ready,  // high when idle
    output logic       tx      // serial line, idles high
);

  localparam int unsigned ClksPerBit = CLK_HZ / BAUD;
  localparam int unsigned CntW = $clog2(ClksPerBit);

  // Elaboration-time check, matching uart_rx (spec 6.3.3).
  if (ClksPerBit < 16) begin : g_baud_check
    $error("uart_tx: CLK_HZ/BAUD must be >= 16");
  end

  logic [9:0] shreg;  // {stop, data[7:0], start}; shreg[0] drives tx
  logic [3:0] bits_left;
  logic [CntW-1:0] cnt;
  logic busy;

  assign ready = !busy;
  assign tx = shreg[0];

  always_ff @(posedge clk) begin
    if (rst) begin
      shreg     <= '1;  // line idles high
      bits_left <= '0;
      cnt       <= '0;
      busy      <= 1'b0;
    end else if (!busy) begin
      if (valid) begin
        shreg     <= {1'b1, data, 1'b0};
        bits_left <= 4'd10;
        cnt       <= '0;
        busy      <= 1'b1;
      end
    end else begin
      if (cnt == CntW'(ClksPerBit - 1)) begin
        cnt   <= '0;
        shreg <= {1'b1, shreg[9:1]};  // shift 1s in: ends at idle-high
        if (bits_left == 4'd1) busy <= 1'b0;
        else bits_left <= bits_left - 4'd1;
      end else begin
        cnt <= cnt + 1'b1;
      end
    end
  end

endmodule
