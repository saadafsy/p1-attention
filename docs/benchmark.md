# Phase 2 benchmark: attention_top cycle counts vs the CPU golden model

Sources (both machine-generated, reproducible):
- Accelerator side: tb/attention_top/cycles.txt, recorded by the cocotb
  end-to-end test; every value matches the closed-form model
  cycles = nblk*(16*nblk+156)+1 with nblk = N/4 (docs/uarch.md 8.3) exactly.
- CPU side: build/cpu_baseline.txt from scripts/benchmark_cpu.py: the
  bit-exact C++ golden model (attn.cpp, -O2, single thread), median of 15
  full-process runs, with the measured process floor (startup + file I/O,
  1.154 ms) subtracted to estimate compute-only time. This baseline is a
  GOLDEN MODEL, not a tuned BLAS kernel; the comparison is honest about that.

Clock disclaimer: cycle counts are clock-independent simulation facts. The
times below are ILLUSTRATIVE at two clocks: 44 MHz is the current
softmax-limited sky130 tt baseline from the Phase 4 infrastructure smoke run
(build/sta_online_softmax.log, slack -12.882 at 10 ns, path ~22.9 ns); 100
MHz is the post-pipelining target that the docs/uarch.md 8.2 registered-ROM
hook aims at and the Basys 3 clock for Phase 6. Neither is a signed-off Fmax;
Phase 4 produces that.

| N  | cycles | @44 MHz | @100 MHz | CPU compute-only | speedup @44 | @100 |
|----|--------|---------|----------|------------------|-------------|------|
| 4  | 173    | 3.9 us  | 1.7 us   | ~0 (below floor resolution) | n/a | n/a |
| 8  | 377    | 8.6 us  | 3.8 us   | ~0 (below floor resolution) | n/a | n/a |
| 16 | 881    | 20.0 us | 8.8 us   | 82 us            | 4.1x        | 9.3x |
| 32 | 2273   | 51.7 us | 22.7 us  | 140 us           | 2.7x        | 6.2x |
| 64 | 6593   | 149.8 us| 65.9 us  | 275 us           | 1.8x        | 4.2x |

(CPU compute-only = median minus the 1.154 ms process floor; at N = 4 and 8
the subtraction is inside measurement noise and no speedup is claimed.)

Utilization view (clock-free, the more meaningful number): one N = 64
inference performs 2 * N^2 * D = 131,072 MAC operations on the Q.K^T side
plus the same again on the PV side, about 262k MACs plus 4,096 exp lookups
and 1,024 divisions, in 6,593 cycles: roughly 40 sustained MAC/cycle against
32 instantiated multipliers (16 tile + 16 PV), i.e. the datapath stays over
100% busy on multiplies when both sides overlap (drain of block b overlaps
compute of block b+1), with the gap to the ideal 32/cycle floor coming from
the group tails (S_DRAIN_LAST + S_DIVIDE, 156 cycles per group).

Honest caveats, in order of importance:
1. The CPU baseline is the reference model, compiled -O2 but written for
   bit-exactness, not speed (arbitrary-width int64 arithmetic, asserts on).
   A vectorized int8 kernel on a modern core would be much faster; this
   table demonstrates the accelerator's cycle economy, not victory over
   optimized CPU software.
2. The speedup column inherits the clock disclaimer; only the cycle counts
   and the CPU milliseconds are measurements.
3. Scaling: accelerator cycles grow ~N^2 (the 16*nblk^2 term dominates), the
   same asymptotic as the CPU; the constant factor is the story, plus the
   deterministic latency (no cache effects).
