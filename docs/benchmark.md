# Benchmark: timing, throughput, accuracy, resources

All numbers here are regenerable from a clone with the commands listed.
None of them is a hardware measurement: timing is static timing analysis
at the sky130 typical corner, and FPGA numbers are synthesis counts.

## Timing (sky130_fd_sc_hd, tt 25C 1.80V, OpenSTA, 10 ns target)

| block | config | setup slack @ 10 ns | meets |
|-------|--------|---------------------|-------|
| matmul_tile (4x4 MAC array) | - | +3.37 ns | ~150 MHz |
| online_softmax | PIPE_ROM=1 (registered ROM) | +0.51 ns | 100 MHz |
| online_softmax | PIPE_ROM=0 (single cycle) | -1.76 ns | ~85 MHz |
| attention_top (whole engine) | PIPE_ROM=1, SRAM macros as flop boundaries | -0.62 ns | ~94 MHz |

Commands: `make sta MODULE=matmul_tile`, `make sta-pipe1`,
`make synth-netlist MODULE=online_softmax && make sta MODULE=online_softmax`,
`make sta-top` (summary in build/sta_attention_top_summary.txt).

Flow: yosys with Booth multipliers, Kogge-Stone adders and a flattened
netlist, ABC mapping with a 10 ns delay target plus buffering and gate
sizing (scripts/abc_timing.abc), OpenSTA with ideal clocks and zero I/O
delay. What it does not include: placement and wire parasitics, clock
tree, and (for attention_top) the SRAM macros' own access time, because no
sky130 SRAM liberty is part of this flow. A placed-and-routed result would
differ; the ranking of paths would not change much.

History, so the numbers can be compared: the first flow mapped area-only
(no delay target, minimum-size cells, no buffering). On the same tools it
reported online_softmax -12.2 ns (PIPE_ROM=0) and -2.5 ns (PIPE_ROM=1),
and attention_top -526 ns, the last because the memories flattened into
32k flip-flops driven by unbuffered selects. The changes that took it to
the table above are in docs/uarch.md 8.4 (RTL) and the Makefile header
(flow).

## Throughput (clock-free, from the cycle formula)

cycles = nblk * (16 * nblk + 156) + 1, nblk = N / 4 (docs/uarch.md 8.3;
tb/attention_top checks it exactly for every run). MACs per inference are
N^2 * D for Q.K^T plus N^2 * D for P.V.

| N | cycles | MACs | MAC/cycle | of 32 MAC units | time @ 94 MHz |
|---|--------|------|-----------|-----------------|---------------|
| 4 | 173 | 512 | 3.0 | 9% | 1.8 us |
| 8 | 377 | 2048 | 5.4 | 17% | 4.0 us |
| 16 | 881 | 8192 | 9.3 | 29% | 9.4 us |
| 32 | 2273 | 32768 | 14.4 | 45% | 24.1 us |
| 64 | 6593 | 131072 | 19.9 | 62% | 70.0 us |

The 32 MAC units are the 16 in the tile plus the 16 w*v columns (the 16
acc*r rescale multipliers are overhead, not MACs). The gap to 100% is the
per-group tail (S_DRAIN_LAST + S_DIVIDE, 156 cycles per group, 38% of a
group at N = 64) and the PV side idling during block 0 of every group.
I/O is not in the cycle count: loading Q, K, V through the byte-serial
port costs 3 * N * D cycles (3072 at N = 64) and reading the output back
N * D more.

## Accuracy vs float64

The bit-exact model (which the RTL matches every cycle) against float64
attention on the same dequantized inputs, 20 seeds per row, errors in
output LSBs (Q1.6, 1 LSB = 1/64). The floor is 0.5 LSB: rounding an exact
float result to Q1.6 already costs that. `python3 scripts/accuracy.py`.

| inputs | N | max err | mean err | within 1 LSB | equal to rounded float |
|--------|---|---------|----------|--------------|------------------------|
| uniform int8 | 4 | 0.80 | 0.262 | 100% | 92.7% |
| uniform int8 | 16 | 0.82 | 0.258 | 100% | 92.8% |
| uniform int8 | 64 | 0.72 | 0.255 | 100% | 94.6% |
| gaussian (sigma 0.5) | 4 | 0.60 | 0.259 | 100% | 95.6% |
| gaussian (sigma 0.5) | 16 | 0.59 | 0.249 | 100% | 97.4% |
| gaussian (sigma 0.5) | 64 | 0.58 | 0.249 | 100% | 98.3% |

Every output is within 1 LSB of float64, and 93 to 98% are exactly the
rounded float answer.

## FPGA resources (Artix-7, yosys synth_xilinx, synthesis only)

fpga/attn_uart_top.sv (engine plus UART wrapper), `bash scripts/fpga_resources.sh`:

| resource | used | Basys 3 (XC7A35T) |
|----------|------|-------------------|
| DSP48E1 | 84 | 90 |
| RAMB18E1 | 6 | 100 |
| RAM64M (distributed RAM) | 96 | - |
| LUTs (LUT1-LUT6) | about 8.7k | 20,800 |
| flip-flops | about 5.0k | 41,600 |

Q and K and the four exp ROMs are block RAM, V and out are distributed
RAM: none of the memories is built from flip-flops. Placement, routing
and the FPGA Fmax need Vivado (fpga/scripts/build.tcl), which has not been
run.

## Against a laptop CPU

One attention head, N = 64, D = 16, one CPU core (AMD Ryzen AI 9 HX 370,
WSL, g++ -O3 -march=native, scripts/pc_bench.cpp), four runs each:

| Runs on | Time per head |
|---|---|
| Laptop CPU, float32 attention | 76 to 88 us |
| Laptop CPU, the bit-exact C++ golden model | 223 to 243 us |
| This engine at the sky130 signoff clock (79.4 MHz, 6,593 cycles) | 83 us |
| This engine at the Vivado clock on the Basys 3 (62.5 MHz) | 105 us |
| RV32IM core in [p2-riscv-soc](https://github.com/saadafsy/p2-riscv-soc), optimized C | about 25 ms |

The engine matches one laptop core while clocked about 50 times slower,
with 16 multipliers. Its OpenROAD power estimate is 149 mW, about 12 uJ per
head at 79.4 MHz (tool estimate, not measured on silicon). The laptop's
power was not measured.

