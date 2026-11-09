`timescale 1ns / 1ps
// uart_rx: 8N1 receiver (docs/phase6_fpga_guide.md 6.3.3). Each bit is a
// majority-of-3 vote at Mid-Step, Mid, Mid+Step; a failed stop vote drops the
// byte. Returns to idle mid-stop so back-to-back frames tolerate baud mismatch.
// rx must already be synchronized to clk.
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

  // Below 16 clocks per bit, Step is 0 and the three samples coincide.
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
          // s2 lands at Mid+Step; decide one cycle later.
          if (cnt == CntW'(Mid + Step + 1)) begin
            cnt   <= '0;
            state <= RX_IDLE;
            if (maj) begin
              data  <= shreg;
              valid <= 1'b1;
            end
          end else begin
            cnt <= cnt + 1'b1;
          end
        end

        default: state <= RX_IDLE;
      endcase
    end
  end

endmodule
