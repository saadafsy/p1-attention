`timescale 1ns / 1ps
// attn_uart_top: Phase 6 UART demo top (docs/phase6_fpga_guide.md 6.2/6.3).
// Wraps attention_top (rtl/attention_top.sv, UNMODIFIED, no parameters)
// with an 8N1 UART (115200 default) command protocol so a pyserial host
// script can load Q/K/V, set n_len, run, poll status, and read the output
// and cycle count back. NORMATIVE protocol: guide section 6.3.4; command
// bytes are localparams below. Port names match the section 5 XDC.
//
// Hierarchy: sync2ff (rst_btn; its own rst tied 0, documented exemption in
// guide 6.3 and fpga/sync2ff.sv), sync2ff (uart_rx line, reset value 1 =
// idle), heartbeat (led0), uart_rx, uart_tx, attention_top.
//
// Protocol FSM states (one hot decision per received/sent byte; the FSM
// stalls on uart_tx's valid/ready handshake, never drops):
//   P_CMD    await a command byte
//   P_LROW   LOAD_Q/K/V: await the row-index byte
//   P_LDATA  LOAD_Q/K/V: 16 data bytes; each rx_valid pulses we into
//            attention_top's sel/addr/wdata/we load port at {row, col}
//   P_NLEN   SET_NLEN: await the n_len byte (stored, sampled by the core
//            only at start; contract: multiple of 4 in [4, 64])
//   P_OROW   READ_OUT: await the row-index byte
//   P_OPIPE  READ_OUT: one dead cycle matching rd_data's registered
//            1-cycle latency (rd_addr is held combinationally from
//            row_reg/col_cnt, so one cycle after col_cnt changes rd_data
//            is the addressed byte and stays stable while we wait for tx)
//   P_OSEND  READ_OUT: send rd_data, then next col or back to P_CMD
//   P_CSEND  READ_CYCLES: send 4 bytes of the snapshot, little-endian
//   P_SEND   send one response byte (ack echo, PING 0xA5, NAK 0x3F,
//            or the status byte), then back to P_CMD
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

  // Command bytes (ASCII where printable) and fixed responses.
  // Normative table: docs/phase6_fpga_guide.md 6.3.4.
  localparam logic [7:0] CmdPing = 8'h50;  // 'P' -> 0xA5
  localparam logic [7:0] CmdLoadQ = 8'h51;  // 'Q' [row][16 bytes] -> echo
  localparam logic [7:0] CmdLoadK = 8'h4B;  // 'K' [row][16 bytes] -> echo
  localparam logic [7:0] CmdLoadV = 8'h56;  // 'V' [row][16 bytes] -> echo
  localparam logic [7:0] CmdNlen = 8'h4E;  // 'N' [n_len] -> echo
  localparam logic [7:0] CmdRun = 8'h52;  // 'R' -> echo, or NAK if busy
  localparam logic [7:0] CmdStatus = 8'h53;  // 'S' -> {6'b0, done_latch, busy}
  localparam logic [7:0] CmdRead = 8'h4F;  // 'O' [row] -> 16 bytes
  localparam logic [7:0] CmdCycles = 8'h43;  // 'C' -> 4 bytes LE
  localparam logic [7:0] RespPing = 8'hA5;
  localparam logic [7:0] RespNak = 8'h3F;  // '?'

  // -----------------------------------------------------------------
  // Synchronizers, heartbeat, UART.
  // -----------------------------------------------------------------
  logic rst;
  logic rx_line_s;

  // Reset-button synchronizer: rst tied 0 (cannot be reset by its own
  // output; settles in 2 cycles). Documented exemption, guide 6.3.
  sync2ff #(
      .WIDTH(1),
      .RST_VAL(1'b0)
  ) u_sync_rst (
      .clk(clk),
      .rst(1'b0),
      .d  (rst_btn),
      .q  (rst)
  );

  // RX-line synchronizer: reset value 1 = UART idle, so reset can never
  // fabricate a start bit.
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

  // -----------------------------------------------------------------
  // Protocol FSM state.
  // -----------------------------------------------------------------
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

  logic [1:0] sel_reg;  // 0=Q, 1=K, 2=V (attention_top load-port encoding)
  logic [5:0] row_reg;
  logic [3:0] col_cnt;
  logic [7:0] resp_reg;  // single-byte response for P_SEND
  logic [31:0] cc_snap;  // cycle_count snapshot, taken at the 'C' byte
  logic [1:0] cc_idx;
  logic [6:0] n_len_reg;  // reset default 16; hosts should always SET_NLEN
  logic done_latch;  // set on done pulse, cleared when RUN accepted
  logic start_reg;  // registered 1-cycle start pulse

  // -----------------------------------------------------------------
  // attention_top (default parameters; ports per rtl/attention_top.sv,
  // normative spec docs/uarch.md 8.3).
  // -----------------------------------------------------------------
  logic        attn_we;
  logic        attn_busy;
  logic        attn_done;
  logic [ 7:0] attn_rd_data;
  logic [31:0] attn_cycle_count;

  // Load writes strobe once per received payload byte; read address is
  // held from the same row/col registers (only one of the two paths is
  // active in any state, so sharing is safe).
  assign attn_we = (state == P_LDATA) && rx_valid;

  attention_top u_attn (
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

  // -----------------------------------------------------------------
  // TX byte select (all outputs defaulted: no latches).
  // -----------------------------------------------------------------
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

  // -----------------------------------------------------------------
  // Protocol FSM.
  // -----------------------------------------------------------------
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
      start_reg <= 1'b0;  // 1-cycle pulse unless re-set below
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
                sel_reg  <= 2'd0;
                resp_reg <= rx_byte;
                state    <= P_LROW;
              end
              CmdLoadK: begin
                sel_reg  <= 2'd1;
                resp_reg <= rx_byte;
                state    <= P_LROW;
              end
              CmdLoadV: begin
                sel_reg  <= 2'd2;
                resp_reg <= rx_byte;
                state    <= P_LROW;
              end
              CmdNlen: begin
                resp_reg <= rx_byte;
                state    <= P_NLEN;
              end
              CmdRun: begin
                // attention_top accepts start only when idle; NAK instead
                // of a silently-dropped pulse when busy (guide 6.3.4).
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
                state <= P_OROW;
              end
              CmdCycles: begin
                cc_snap <= attn_cycle_count;
                cc_idx  <= '0;
                state   <= P_CSEND;
              end
              default: begin
                resp_reg <= RespNak;  // unknown command (guide 6.3.4)
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
            // attn_we strobes this cycle (combinational above), writing
            // rx_byte at {row_reg, col_cnt}.
            col_cnt <= col_cnt + 4'd1;  // wraps to 0 with the transition
            if (col_cnt == 4'd15) state <= P_SEND;  // ack after byte 16
          end
        end

        P_NLEN: begin
          if (rx_valid) begin
            n_len_reg <= rx_byte[6:0];
            state     <= P_SEND;
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
          // rd_addr already points at {row_reg, col_cnt}; after this
          // cycle attention_top's registered rd_data holds that byte.
          state <= P_OSEND;
        end

        P_OSEND: begin
          if (tx_ready) begin
            // tx_valid is high in this state: transfer happens this edge.
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
