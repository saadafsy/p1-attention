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
times below are ILLUSTRATIVE at the two Phase 4 signed clocks for the
online_softmax block, the design's expected Fmax limiter
([EVIDENCE: phase4-sta], docs/tradeoffs.md): 38.5 MHz is the met period of
the default comb-ROM config (26 ns, sky130 tt), 76.9 MHz the met period of
the PIPE_ROM=1 registered-ROM variant (13 ns). Both are block-level OpenSTA
tool estimates; attention_top itself instantiates the default config and its
integrated netlist has not been through STA, so neither column is a signed
Fmax for the top. Earlier revisions of this file quoted 44 MHz from a
pre-Phase-4 smoke run of the same log; superseded.

| N  | cycles | @38.5 MHz | @76.9 MHz | CPU compute-only | speedup @38.5 | @76.9 |
|----|--------|-----------|-----------|------------------|---------------|-------|
| 4  | 173    | 4.5 us    | 2.2 us    | ~0 (below floor resolution) | n/a | n/a |
| 8  | 377    | 9.8 us    | 4.9 us    | ~0 (below floor resolution) | n/a | n/a |
| 16 | 881    | 22.9 us   | 11.5 us   | 82 us            | 3.6x          | 7.1x  |
| 32 | 2273   | 59.0 us   | 29.6 us   | 140 us           | 2.4x          | 4.7x  |
| 64 | 6593   | 171.2 us  | 85.7 us   | 275 us           | 1.6x          | 3.2x  |

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
