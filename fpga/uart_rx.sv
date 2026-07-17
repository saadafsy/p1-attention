`timescale 1ns / 1ps
// uart_rx: 8N1 serial receiver (Phase 6 bring-up kit; normative physical
// layer spec: docs/phase6_fpga_guide.md 6.3.3).
//
// Frame: 1 start (low), 8 data bits LSB first, 1 stop (high), no parity.
// Pacing: a full-rate counter counts ClksPerBit = CLK_HZ / BAUD clocks
// per bit cell (868 at 100 MHz / 115200, actual baud 115207, +0.006%).
// Each bit value is a MAJORITY-OF-3 vote of samples taken at counts
// Mid - Step, Mid, Mid + Step (Mid = ClksPerBit/2 = 434,
// Step = ClksPerBit/16 = 54), so a 1-sample glitch never corrupts a bit.
// The start bit is qualified by the same vote (false start: silently back
// to idle). A failed stop-bit vote is a framing error: the byte is DROPPED
// silently, no valid pulse. The receiver returns to idle just after the
// stop vote (Mid + Step + 1), not at the end of the stop cell, so
// back-to-back frames tolerate small baud mismatch.
//
// Interface: data holds the last good byte; valid is a 1-cycle pulse.
// rx MUST already be synchronized to clk (sync2ff upstream).
module uart_rx #(
    parameter int unsigned CLK_HZ = 100_000_000,
    parameter int unsigned BAUD   = 115_200
) (
    input  logic       clk,
    input  logic       rst,   // synchronous, active-high
    input  logic       rx,    // serial line, already synchronized
    output logic [7:0] data,  // last received byte, LSB was first on the wire
    output logic       valid  // 1-cycle pulse: data is a new good frame
);

  localparam int unsigned ClksPerBit = CLK_HZ / BAUD;
  localparam int unsigned Mid = ClksPerBit / 2;
  localparam int unsigned Step = ClksPerBit / 16;
  localparam int unsigned CntW = $clog2(ClksPerBit);

  // Elaboration-time check (spec 6.3.3): with fewer than 16 clocks per bit
  // the vote spacing Step collapses to 0 and the three samples coincide.
  if (ClksPerBit < 16) begin : g_baud_check
    $error("uart_rx: CLK_HZ/BAUD must be >= 16");
  end

  typedef enum logic [1:0] {
    RX_IDLE,
    RX_START,
    RX_DATA,
    RX_STOP
  } rx_state_e;

  rx_state_e state;
  logic [CntW-1:0] cnt;
  logic [2:0] bit_idx;
  logic [7:0] shreg;
  logic s0, s1, s2;

  // Majority-of-3 vote over this bit cell's samples.
  wire maj = (s0 & s1) | (s0 & s2) | (s1 & s2);

  always_ff @(posedge clk) begin
    if (rst) begin
      state   <= RX_IDLE;
      cnt     <= '0;
      bit_idx <= '0;
      shreg   <= '0;
      s0      <= 1'b1;
      s1      <= 1'b1;
      s2      <= 1'b1;
      data    <= '0;
      valid   <= 1'b0;
    end else begin
      valid <= 1'b0;

      // Sample capture, common to all active bit cells.
      if (state != RX_IDLE) begin
        if (cnt == CntW'(Mid - Step)) s0 <= rx;
        if (cnt == CntW'(Mid)) s1 <= rx;
        if (cnt == CntW'(Mid + Step)) s2 <= rx;
      end

      unique case (state)
        RX_IDLE: begin
          if (!rx) begin
            state <= RX_START;
            cnt   <= '0;
          end
        end

        RX_START: begin
          if (cnt == CntW'(ClksPerBit - 1)) begin
            cnt <= '0;
            if (!maj) begin
              state   <= RX_DATA;
              bit_idx <= '0;
            end else begin
              state <= RX_IDLE;  // false start (glitch): emit nothing
            end
          end else begin
            cnt <= cnt + 1'b1;
          end
        end

        RX_DATA: begin
          if (cnt == CntW'(ClksPerBit - 1)) begin
            cnt   <= '0;
            shreg <= {maj, shreg[7:1]};  // LSB first
            if (bit_idx == 3'd7) state <= RX_STOP;
            else bit_idx <= bit_idx + 3'd1;
          end else begin
            cnt <= cnt + 1'b1;
          end
        end

        RX_STOP: begin
          // s2 lands at Mid+Step; decide one cycle later and return to
          // idle early (mid-stop) for back-to-back frame tolerance.
          if (cnt == CntW'(Mid + Step + 1)) begin
            cnt   <= '0;
            state <= RX_IDLE;
            if (maj) begin
              data  <= shreg;
              valid <= 1'b1;
            end
            // else: framing error, byte dropped silently (spec 6.3.3)
          end else begin
            cnt <= cnt + 1'b1;
          end
        end

        default: state <= RX_IDLE;
      endcase
    end
  end

endmodule
