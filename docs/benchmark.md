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

Utilization view (clock-free, the more meaningful number). Corrected
2026-09-18: the earlier revision counted 2 * N^2 * D = 131,072 "MACs" per
side, which is the multiply-and-add OPERATION count, and then called the
262k total MACs; the resulting "over 100% busy" conclusion was impossible
on its face and was the tell. One N = 64 inference performs N^2 * D =
65,536 MACs on the Q.K^T side and 65,536 on the PV side, 131,072 MACs in
total, plus 8,192 exp lookups (w and r per element) and 1,024 divisions, in
6,593 cycles: 19.9 sustained MAC/cycle. The engine instantiates 48
multipliers (16 in the tile, 16 acc*r rescale and 16 w*v in the shared PV
datapath, docs/uarch.md 8.3); against the 32 that perform golden-model MACs
(tile + w*v) that is 62% utilization, and against all 48 it is 41%. The gap
to the ideal comes from the group tails (S_DRAIN_LAST + S_DIVIDE, 156
cycles per group, 38% of the 412-cycle group at N = 64) and from the PV
side idling during block 0 of every group (nothing to drain yet).

Scope of the cycle counts: cycle_count covers the run only, from the
accepted start pulse to done. Loading Q, K and V through the byte-serial
load port costs 3 * N * D cycles on top (3,072 cycles at N = 64, i.e. 47%
of the 6,593-cycle run) and reading the output back another N * D; the
speedup column therefore ignores I/O entirely, which is the usual
accelerator-benchmark convention but must be said.

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
