// online_softmax with the registered exp ROM (PIPE_ROM=1), the configuration
// attention_top uses; a wrapper only because the flow cannot set parameters.
module online_softmax_pipe1 (
    input  logic               clk,
    input  logic               rst,
    input  logic               in_valid,
    input  logic               row_start,
    input  logic signed [15:0] s,
    output logic        [15:0] w,
    output logic        [15:0] r,
    output logic               out_valid,
    output logic        [23:0] l,
    output logic signed [15:0] m
);
  online_softmax #(.PIPE_ROM(1'b1)) u_sm (.*);
endmodule
