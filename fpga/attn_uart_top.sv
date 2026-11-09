`timescale 1ns / 1ps
// attn_uart_top: FPGA demo top wrapping attention_top with an 8N1 UART
// command protocol (docs/phase6_fpga_guide.md 6.3.4) for fpga/host/attn_host.py.
// Port names match the board XDC files.
module attn_uart_top #(
    parameter int unsigned CLK_HZ = 100_000_000,
    parameter int unsigned BAUD   = 115_200
) (
    input  logic clk,      // 100 MHz board oscillator (W5)
    input  logic rst_btn,  // center button, active high when pressed (U18)
    input  logic uart_rx,  // from USB-UART bridge, host transmits here (B18)
    output logic uart_tx,  // to USB-UART bridge, host receives here (A18)
    output logic led0      // heartbeat (U16)
);

  // Command bytes and fixed responses.
  localparam logic [7:0] CmdPing = 8'h50;  // 'P' -> 0xA5
  localparam logic [7:0] CmdLoadQ = 8'h51;  // 'Q' [row][16 bytes] -> echo, or NAK if busy
  localparam logic [7:0] CmdLoadK = 8'h4B;  // 'K' [row][16 bytes] -> echo, or NAK if busy
  localparam logic [7:0] CmdLoadV = 8'h56;  // 'V' [row][16 bytes] -> echo, or NAK if busy
  localparam logic [7:0] CmdNlen = 8'h4E;  // 'N' [n_len] -> echo, or NAK if out of contract
  localparam logic [7:0] CmdRun = 8'h52;  // 'R' -> echo, or NAK if busy
  localparam logic [7:0] CmdStatus = 8'h53;  // 'S' -> {6'b0, done_latch, busy}
  localparam logic [7:0] CmdRead = 8'h4F;  // 'O' [row] -> 16 bytes, or NAK if busy
  localparam logic [7:0] CmdCycles = 8'h43;  // 'C' -> 4 bytes LE, or NAK if busy
  localparam logic [7:0] RespPing = 8'hA5;
  localparam logic [7:0] RespNak = 8'h3F;  // '?'

  logic rst;
  logic rx_line_s;

  // Reset synchronizer cannot be reset by its own output, so its rst is tied 0.
  sync2ff #(
      .WIDTH(1),
      .RST_VAL(1'b0)
  ) u_sync_rst (
      .clk(clk),
      .rst(1'b0),
      .d  (rst_btn),
      .q  (rst)
  );

  // Reset value 1 (idle) so reset cannot fabricate a start bit.
  sync2ff #(
      .WIDTH(1),
      .RST_VAL(1'b1)
  ) u_sync_rx (
      .clk(clk),
      .rst(rst),
      .d  (uart_rx),
      .q  (rx_line_s)
  );

  heartbeat #(
      .CLK_HZ(CLK_HZ)
  ) u_heartbeat (
      .clk(clk),
      .rst(rst),
      .led(led0)
  );

  logic [7:0] rx_byte;
  logic       rx_valid;

  uart_rx #(
      .CLK_HZ(CLK_HZ),
      .BAUD  (BAUD)
  ) u_rx (
      .clk  (clk),
      .rst  (rst),
      .rx   (rx_line_s),
      .data (rx_byte),
      .valid(rx_valid)
  );

  logic [7:0] tx_data;
  logic       tx_valid;
  logic       tx_ready;

  uart_tx #(
      .CLK_HZ(CLK_HZ),
      .BAUD  (BAUD)
  ) u_tx (
      .clk  (clk),
      .rst  (rst),
      .data (tx_data),
      .valid(tx_valid),
      .ready(tx_ready),
      .tx   (uart_tx)
  );

  typedef enum logic [3:0] {
    P_CMD,
    P_LROW,
    P_LDATA,
    P_NLEN,
    P_OROW,
    P_OPIPE,
    P_OSEND,
    P_CSEND,
    P_SEND
  } pstate_e;

  pstate_e state;

  logic [1:0] sel_reg;  // 0=Q, 1=K, 2=V
  logic [5:0] row_reg;
  logic [3:0] col_cnt;
  logic [7:0] resp_reg;  // single-byte response for P_SEND
  logic [31:0] cc_snap;
  logic [1:0] cc_idx;
  logic [6:0] n_len_reg;  // reset default 16
  logic done_latch;  // set on done, cleared when RUN is accepted
  logic start_reg;

  logic        attn_we;
  logic        attn_busy;
  logic        attn_done;
  logic [ 7:0] attn_rd_data;
  logic [31:0] attn_cycle_count;

  // Load and read share {row_reg, col_cnt}; only one path is active per state.
  assign attn_we = (state == P_LDATA) && rx_valid;

  // PIPE_ROM = 1: registered exp ROM (block RAM) for timing.
  // PV_SPLIT = 0: one PV product per column maps onto DSP48 (split would need ~150 DSPs).
  attention_top #(
      .PIPE_ROM(1'b1),
      .PV_SPLIT(1'b0)
  ) u_attn (
      .clk        (clk),
      .rst        (rst),
      .sel        (sel_reg),
      .addr       ({row_reg, col_cnt}),
      .wdata      (rx_byte),
      .we         (attn_we),
      .n_len      (n_len_reg),
      .start      (start_reg),
      .busy       (attn_busy),
      .done       (attn_done),
      .rd_addr    ({row_reg, col_cnt}),
      .rd_data    (attn_rd_data),
      .cycle_count(attn_cycle_count)
  );

  always_comb begin
    tx_valid = 1'b0;
    tx_data  = 8'h00;
    unique case (state)
      P_SEND: begin
        tx_valid = 1'b1;
        tx_data  = resp_reg;
      end
      P_OSEND: begin
        tx_valid = 1'b1;
        tx_data  = attn_rd_data;
      end
      P_CSEND: begin
        tx_valid = 1'b1;
        tx_data  = cc_snap[8*cc_idx+:8];
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state      <= P_CMD;
      sel_reg    <= '0;
      row_reg    <= '0;
      col_cnt    <= '0;
      resp_reg   <= '0;
      cc_snap    <= '0;
      cc_idx     <= '0;
      n_len_reg  <= 7'd16;
      done_latch <= 1'b0;
      start_reg  <= 1'b0;
    end else begin
      start_reg <= 1'b0;
      if (attn_done) done_latch <= 1'b1;

      unique case (state)
        P_CMD: begin
          if (rx_valid) begin
            case (rx_byte)
              CmdPing: begin
                resp_reg <= RespPing;
                state    <= P_SEND;
              end
              CmdLoadQ: begin
                // A load while busy would corrupt the run: NAK, consume no payload.
                if (attn_busy) begin
                  resp_reg <= RespNak;
                  state    <= P_SEND;
                end else begin
                  sel_reg  <= 2'd0;
                  resp_reg <= rx_byte;
                  state    <= P_LROW;
                end
              end
              CmdLoadK: begin
                if (attn_busy) begin
                  resp_reg <= RespNak;
                  state    <= P_SEND;
                end else begin
                  sel_reg  <= 2'd1;
                  resp_reg <= rx_byte;
                  state    <= P_LROW;
                end
              end
              CmdLoadV: begin
                if (attn_busy) begin
                  resp_reg <= RespNak;
                  state    <= P_SEND;
                end else begin
                  sel_reg  <= 2'd2;
                  resp_reg <= rx_byte;
                  state    <= P_LROW;
                end
              end
              CmdNlen: begin
                resp_reg <= rx_byte;
                state    <= P_NLEN;
              end
              CmdRun: begin
                // start is ignored while busy, so NAK rather than drop it silently.
                if (attn_busy) begin
                  resp_reg <= RespNak;
                end else begin
                  start_reg  <= 1'b1;
                  done_latch <= 1'b0;
                  resp_reg   <= rx_byte;
                end
                state <= P_SEND;
              end
              CmdStatus: begin
                resp_reg <= {6'b0, done_latch, attn_busy};
                state    <= P_SEND;
              end
              CmdRead: begin
                // out_mem is being written during a run: NAK.
                if (attn_busy) begin
                  resp_reg <= RespNak;
                  state    <= P_SEND;
                end else begin
                  state <= P_OROW;
                end
              end
              CmdCycles: begin
                // cycle_count is final only once idle.
                if (attn_busy) begin
                  resp_reg <= RespNak;
                  state    <= P_SEND;
                end else begin
                  cc_snap <= attn_cycle_count;
                  cc_idx  <= '0;
                  state   <= P_CSEND;
                end
              end
              default: begin
                resp_reg <= RespNak;  // unknown command
                state    <= P_SEND;
              end
            endcase
          end
        end

        P_LROW: begin
          if (rx_valid) begin
            row_reg <= rx_byte[5:0];
            col_cnt <= '0;
            state   <= P_LDATA;
          end
        end

        P_LDATA: begin
          if (rx_valid) begin
            col_cnt <= col_cnt + 4'd1;  // wraps to 0 with the transition
            if (col_cnt == 4'd15) state <= P_SEND;  // ack after byte 16
          end
        end

        P_NLEN: begin
          if (rx_valid) begin
            // Accept only multiples of 4 in [4, 64]; bit 7 is rejected.
            if (rx_byte[7] == 1'b0 && rx_byte[1:0] == 2'b00 &&
                rx_byte[6:2] != 5'd0 && rx_byte[6:2] <= 5'd16) begin
              n_len_reg <= rx_byte[6:0];  // resp_reg already holds the echo
            end else begin
              resp_reg <= RespNak;  // stored value unchanged
            end
            state <= P_SEND;
          end
        end

        P_OROW: begin
          if (rx_valid) begin
            row_reg <= rx_byte[5:0];
            col_cnt <= '0;
            state   <= P_OPIPE;
          end
        end

        P_OPIPE: begin
          // One cycle for the registered rd_data to catch up with rd_addr.
          state <= P_OSEND;
        end

        P_OSEND: begin
          if (tx_ready) begin
            if (col_cnt == 4'd15) begin
              state <= P_CMD;
            end else begin
              col_cnt <= col_cnt + 4'd1;
              state   <= P_OPIPE;
            end
          end
        end

        P_CSEND: begin
          if (tx_ready) begin
            cc_idx <= cc_idx + 2'd1;  // wraps to 0 with the transition
            if (cc_idx == 2'd3) state <= P_CMD;
          end
        end

        P_SEND: begin
          if (tx_ready) state <= P_CMD;
        end

        default: state <= P_CMD;
      endcase
    end
  end

endmodule
