`timescale 1ns / 1ps
// tool_smoke: throwaway Phase -1 module. A resettable counter whose only job is
// to prove the whole verify pipeline (lint, cocotb sim, coverage gate, yosys
// synth-check, sby formal) end to end. Not a P1 datapath block; no Q-format
// applies (pure integer control logic). Delete or ignore after Phase -1.
module tool_smoke #(
    parameter int unsigned Width = 8
) (
    input  logic             clk,
    input  logic             rst,   // synchronous, active-high
    input  logic             en,
    output logic [Width-1:0] count
);

  always_ff @(posedge clk) begin
    if (rst) begin
      count <= '0;
    end else if (en) begin
      count <= count + Width'(1);
    end
  end

`ifdef FORMAL
  // Formal-only scaffolding (exempt from the no-initial-blocks RTL rule: this
  // code is guarded and never synthesized). Properties kept minimal and
  // yosys-parseable per project rule: immediate assertions, no SVA sequences.
  logic f_past_valid;
  initial f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;

  always_ff @(posedge clk) begin
    if (f_past_valid) begin
      if ($past(rst)) begin
        assert (count == '0);
      end else if ($past(en)) begin
        assert (count == Width'($past(count) + Width'(1)));
      end else begin
        assert (count == $past(count));
      end
    end
  end
`endif

endmodule
