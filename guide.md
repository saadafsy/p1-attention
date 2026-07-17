# guide.md: Streaming Attention Engine, Phases -1 to 5 (builder documentation)

Scope of this document: Phase -1 (toolchain smoke test), Phase 0 (bit-accurate
golden models), the four dual-countersigned RTL modules (mac_unit,
matmul_tile, online_softmax, attention_top), and the closed Phases 3, 4 and 5
(functional coverage plus exact-max formal; the PIPE_ROM pipelining iteration
with sky130 synthesis, OpenSTA timing and gate-level simulation; the
switching-activity power proxy and tradeoff writeup). Phases 6 and 7 (FPGA,
GDS/silicon) are future work and stay PENDING-HARDWARE where they need a
bench. Every result claim in this document cites an EVIDENCE.md row id in
brackets, for example [EVIDENCE: verify-mac_unit]. Numbers not present in
EVIDENCE.md cite the repo artifact they were read from, or show their
derivation inline. Per PLAN.md, everything through Phase 5 is [Ready], not
[Done]: the Done gate additionally requires the project owner's Mode-B
replication pass, which has not happened; "closed" below means what it means
in PLAN.md and EVIDENCE.md (verify green, evidence row, countersigned). No em
dashes are used anywhere in this file, per the project docs rule.

## 1. What this is

A fixed-point streaming attention accelerator in SystemVerilog: a tiled
Q.K^T matmul datapath (TPU-paper lineage) feeding an online softmax
(FlashAttention-paper lineage), integrated end to end (attention_top) with
BRAM-inferable memories and a restoring divider bank, with a bit-exact dual
golden model (Python and C++), cocotb simulation against that model,
functional and line coverage, lint, latch-free synthesis checks, bounded
formal proofs, sky130 synthesis with OpenSTA timing, gate-level simulation of
the synthesized netlists, and a switching-activity power proxy.

Honest status in one sentence: the design is verified in simulation and
formal; every module is synthesized to a latch-free netlist (yosys check, 0
problems); the online_softmax core, the design's timing limiter, meets timing
at 38.5 MHz naive and 76.9 MHz pipelined in OpenSTA at the sky130 tt corner
(tool estimates from build/sta_online_softmax_met26ns.log and
build/sta_online_softmax_pipe1_met13ns.log; neither configuration meets the
10 ns target period); nothing is implemented on FPGA and nothing is
fabricated (both are PENDING-HARDWARE).

### 1.1 Status table

| Item | Status | Evidence |
|------|--------|----------|
| Phase -1: tool_smoke through the full verify pipeline | PASS | [EVIDENCE: verify-tool_smoke] |
| Phase 0: golden models bit-identical, LUT emitted, float gate met | PASS | [EVIDENCE: model-crosscheck] |
| rtl/mac_unit.sv | verify green, dual countersigned | [EVIDENCE: verify-mac_unit], [EVIDENCE: audit-mac_unit-lint-synth], [EVIDENCE: audit-mac_unit-formal-coverage] |
| rtl/matmul_tile.sv | verify green, dual countersigned | [EVIDENCE: verify-matmul_tile], [EVIDENCE: audit-matmul_tile-lint-synth], [EVIDENCE: audit-matmul_tile-formal-coverage] |
| rtl/online_softmax.sv | verify green, dual countersigned; re-audited after PIPE_ROM parameterization | [EVIDENCE: verify-online_softmax], [EVIDENCE: audit-online_softmax-lint-synth], [EVIDENCE: audit-online_softmax-formal-coverage], [EVIDENCE: audit-online_softmax-pipe-lint-synth], [EVIDENCE: audit-online_softmax-pipe-formal-coverage] |
| rtl/attention_top.sv (Phase 2) | verify green incl. BRAM-pattern memories, dual countersigned | [EVIDENCE: verify-attention_top], [EVIDENCE: bram-conversion-attention_top], [EVIDENCE: audit-attention_top-lint-synth], [EVIDENCE: audit-attention_top-formal-coverage] |
| Phase 2 benchmark vs CPU golden | closed (docs/benchmark.md) | tb/attention_top/cycles.txt, build/cpu_baseline.txt |
| Phase 3: functional coverage + exact-max formal | closed, 52/52 reachable bins, 18 asserts PASS | [EVIDENCE: phase3-closure] |
| Phase 4: PIPE_ROM variant, sky130 STA, GLS | closed; 10 ns NOT met in either softmax config (documented) | [EVIDENCE: phase4-sta] |
| Phase 5: power proxy + tradeoffs + verification plan | closed | [EVIDENCE: phase5-docs] |
| Phase 6 (FPGA), Phase 7 silicon | PENDING-HARDWARE; Phase 7 GDS is future sandbox work | no rows (none claimable) |

### 1.2 Phase -1: the toolchain gate

Before any project module, a throwaway counter (tool_smoke) was taken through
the entire verify pipeline (verilator and verible lint, cocotb simulation
under verilator, the coverage gate in stub mode, yosys synthesis check, and a
SymbiYosys bounded proof) so that tool breakage could never masquerade as an
RTL bug. `make verify MODULE=tool_smoke` exited 0
[EVIDENCE: verify-tool_smoke]. The artifacts live under tb/tool_smoke/ and
formal/tool_smoke/.

The pipeline that every module must pass, from the repo Makefile, is:

```
lint -> sim (cocotb vs golden) -> coverage gate -> synth-check (yosys, latch grep) -> formal (sby)
```

Definitions used throughout this guide:
- Lint: static analysis of the RTL source (verilator --lint-only -Wall plus
  verible-verilog-lint) for width mismatches, unused signals, and style.
- Inferred latch: storage a synthesis tool creates when a combinational block
  fails to assign an output on some path; latches break the synchronous
  timing model and are banned by the coding standard. The synth-check target
  greps the yosys log for $_DLATCH_ cells and fails if any appear.
- BMC (bounded model check): a formal proof that all assertions hold for
  every possible input sequence up to a fixed depth of clock cycles, run by
  SymbiYosys (sby) with an SMT solver (z3, or yices where noted).
- Line coverage: the fraction of instrumented source lines executed at least
  once in simulation, from verilator --coverage, gated by
  scripts/check_coverage.py at line >= 90% and functional 100%.
- STA (static timing analysis): tool computation of the worst
  register-to-register path delay in a synthesized netlist against a target
  clock period; slack is period minus required path delay, negative slack
  means the period is not met. Run here with OpenSTA 2.0.17 on
  sky130_fd_sc_hd tt_025C_1v80 liberty timing.
- GLS (gate-level simulation): simulating the post-synthesis netlist (sky130
  standard cells, functional models) instead of the RTL, to prove the
  netlist, not just the source, behaves correctly.
- Fmax: the maximum clock frequency implied by the smallest period a netlist
  meets in STA. Every Fmax in this document is a tool estimate at one corner
  in simulation, never a hardware measurement.

## 2. Numeric contract summary

docs/uarch.md is the normative source of truth for every format, width,
rounding site, and saturation site; if code and that file disagree, the code
is the bug (docs/uarch.md, header). This section is a summary with pointers;
nothing here overrides it.

Number formats (docs/uarch.md section 2). Qm.n is signed two's complement
with 1 sign bit, m integer bits, n fractional bits; UQm.n is unsigned.

| Name  | Format | Bits | Used for |
|-------|--------|------|----------|
| ACT   | Q1.6   | 8    | Q, K, V inputs and final output |
| SACC  | Q11.12 | 24   | Q.K^T dot-product accumulator |
| SCORE | Q5.10  | 16   | scaled score s, running max m |
| WGT   | UQ1.15 | 16   | exp() output w, rescale factor r |
| DEN   | UQ9.15 | 24   | softmax denominator accumulator l |
| NUM   | Q10.21 | 32   | weighted-V accumulator (attention_top) |

Fixed configuration (docs/uarch.md section 1): D = 16 (head dimension), so
1/sqrt(D) = 1/4 is an exact right shift by 2 (D_SHIFT = 2) and the score path
needs no scaling multiplier; N_MAX = 256 (architectural), N <= 64 (project
default; attention_top requires n_len a multiple of 4 in [4, 64]).

Rounding policy (docs/uarch.md section 4): ONE rounding mode everywhere,
round-half-up toward +infinity, realized as
`rshr(x, k) = (x + 2^(k-1)) >> k` (arithmetic shift) and
`divr(a, b) = floor((2a + b) / (2b))`. There are exactly six rounding sites
in the whole design (score scale, LUT index, denominator rescale, numerator
rescale, output division, offline LUT generation); everything not on that
list is exact integer math. A single policy means one adder and a wire shift
in RTL, and it removes the classic multi-policy mismatch trap between the
two golden models. Saturation exists at exactly four sites (docs/uarch.md
section 5); the accumulators (SACC, DEN, NUM) have NO saturation because
their widths make overflow impossible for D = 16, N <= 256, with the bounds
proven in docs/uarch.md 3.2, 3.6, 3.7 and asserted at runtime in both models.

Design decision, recorded here because it shapes the whole datapath: the
final output division (docs/uarch.md 3.8) is specified as a true integer
divider rather than a reciprocal LUT plus multiply. The scales are
self-normalizing (num raw is value * 2^21, den raw is value * 2^15, so
num_raw/den_raw is exactly the Q1.6 raw output with no pre- or post-shift),
the denominator is provably >= 2^15 so divide-by-zero cannot occur, and a
reciprocal table would add a multi-LSB relative error source plus a second
rounding site both golden models would have to replicate. The divider was
specified in Phase 0, implemented first in the two golden models, and is now
implemented in RTL as attention_top's 16-wide serial restoring divider bank
(section 7.4), verified bit-exactly end to end
[EVIDENCE: verify-attention_top].

## 3. Golden models (Phase 0)

Files: model/attn.py (normative executable spec), model/attn.cpp
(independent reimplementation, required bit-identical), model/crosscheck.py
(the prover). `make model-check` exits 0: the two models are bit-identical on
all 14 random and corner cases, the exp LUT is emitted, and the
fixed-vs-float error gate is met [EVIDENCE: model-crosscheck].

### 3.1 Why two models, and the floor-vs-trunc trap

The single highest-risk bug class in fixed-point work is a silent rounding
semantics mismatch. Python's `>>` and `//` floor on negative numbers; C++
`/` truncates toward zero. Floor and trunc differ exactly when the numerator
is negative and the division inexact. The two models therefore implement the
same spec through DIFFERENT language mechanisms on purpose: attn.py leans on
Python's floor semantics, attn.cpp routes every rounding through an explicit
floordiv() helper. A floor/trunc confusion in either language shows up as a
byte mismatch in the cross-check. From model/attn.py:

```python
# ---- Rounding helpers (docs/uarch.md section 4) ------------------------------
def rshr(x, k):
    """Round-half-up arithmetic right shift: floor(x/2^k + 1/2)."""
    return (x + (1 << (k - 1))) >> k


def divr(a, b):
    """Round-half-up division a/b for b > 0: floor((2a+b)/(2b))."""
    return (2 * a + b) // (2 * b)


def lut_index(d_raw):
    """Q5.10 difference (<= 0) to LUT index. Clamp to domain, round to grid."""
    assert d_raw <= 0
    if d_raw < LUT_DOMAIN_RAW:
        d_raw = LUT_DOMAIN_RAW
    idx = (-d_raw + 8) >> LUT_STEP_SHIFT
    return idx if idx < LUT_SIZE else LUT_SIZE - 1
```

And the matching C++ from model/attn.cpp:

```cpp
// ---- Rounding helpers (docs/uarch.md section 4) -----------------------------
int64_t floordiv(int64_t a, int64_t b) {
  int64_t q = a / b, r = a % b;
  if (r != 0 && ((r < 0) != (b < 0))) --q;
  return q;
}

// Round-half-up arithmetic right shift: floor(x/2^k + 1/2).
int64_t rshr(int64_t x, int k) {
  return floordiv(x + (int64_t{1} << (k - 1)), int64_t{1} << k);
}

// Round-half-up division a/b, b > 0.
int64_t divr(int64_t a, int64_t b) { return floordiv(2 * a + b, 2 * b); }
```

Both models assert every declared register width bound on every update
(SACC, DEN, NUM), so an overflow of a declared width is an assertion
failure, never a silent wrap.

### 3.2 The cross-check cases

model/crosscheck.py builds attn.cpp with asserts on (no -DNDEBUG), runs both
models on 14 cases, and exits 0 only if every case is byte-exact between the
two AND meets the 6 LSB fixed-vs-float gate of docs/uarch.md section 7.
The case list, pasted from model/crosscheck.py:

```python
CASES = [
    ("rand-n64-s1", rand_case(64, 1)),
    ("rand-n64-s2", rand_case(64, 2)),
    ("rand-n64-s3", rand_case(64, 3)),
    ("rand-n64-s4", rand_case(64, 4)),
    ("rand-n64-s5", rand_case(64, 5)),
    ("rand-n1-s7", rand_case(1, 7)),
    ("rand-n2-s8", rand_case(2, 8)),
    ("rand-n17-s9", rand_case(17, 9)),
    ("rand-n256-s10", rand_case(256, 10)),        # architectural N_MAX
    ("small-mag-s11", rand_case(64, 11, -8, 8)),  # low-SNR regime
    ("zeros-n8", const_case(8, 0)),
    ("allmax-n8", const_case(8, 127)),            # extreme positive scores
    ("allmin-n8", const_case(8, -128)),           # extreme via (-128)^2
    ("monotonic-n64", monotonic_case(64)),        # max update every step
]
```

The monotonic-n64 case exists specifically to force a genuine rescale
(r < 0x8000) with sign-mixed accumulators on every one of its 64 steps, the
exact stimulus where a floor/trunc bug in the rescale rounding would surface
(docs/uarch.md 6.1). The recorded float-gate result: worst deviation 0.77 LSB
(0.0121 in value) against the 6 LSB gate, from the 2026-07-16 model-check run
(recorded in docs/uarch.md section 7; the per-case table is reprinted by
every `make model-check` run) [EVIDENCE: model-crosscheck].

### 3.3 LUT single-source discipline

The exp() table exists ONCE in the project. model/attn.py gen_exp_lut() is
the only generator: lut[j] = floor(2^15 * exp(-j/2^6) + 0.5) for j = 0..1023
(1024 entries, UQ1.15, 2 KB). It is rendered into two artifacts:

1. model/exp_lut.hex, the normative interchange file consumed by attn.cpp,
   pinned by checksum in docs/uarch.md 3.5:
   sha256 = 541676bde3a2a703ec0e021960eed77a1806f6182cd4a8d48803e57302e84ba5
2. rtl/exp_lut.svh, the same table rendered as a synthesizable constant case
   function (exp_lut_rom), emitted only by
   `python3 model/attn.py --emit-lut-svh rtl/exp_lut.svh`, never hand-edited.

Why a generated .svh case function instead of $readmemh: initial blocks are
banned in RTL by the project coding standard, and a memory file path would
resolve differently across the verilator, yosys, sby, and cocotb working
directories (docs/uarch.md 8.2). The generated function keeps the ROM
synthesizable, initial-free, and path-independent. The lint-synth auditor
independently re-emitted the .svh and confirmed it diff-identical to the
generator output [EVIDENCE: audit-online_softmax-lint-synth], and confirmed
this again after the Phase 4 parameterization
[EVIDENCE: audit-online_softmax-pipe-lint-synth]. The online_softmax
testbench re-checks all three renderings (attn.py in-memory table,
exp_lut.hex, exp_lut.svh) entry for entry plus the sha256 pin at import
time, before any simulation starts (tb/online_softmax/
test_online_softmax.py, _check_rom_sources()).

Zero tail: entries 710..1023 are exactly zero (2^15 * exp(-j/64) < 0.5 for
j >= 710), giving natural underflow-to-zero for differences at or below
-11.09; the dropped probability mass is bounded by 256 * exp(-709/64), which
is 0.40% of the denominator at N_MAX and 0.10% at the project N = 64
(derivation in docs/uarch.md 3.5).

Why a direct LUT and not piecewise linear: PWL would add a multiplier to the
exp path and widen every ROM entry (base plus slope) to push an error that
is already below the section 7 output budget further down; the direct LUT
keeps the softmax pipe multiplier-free except for the one rescale multiplier
online softmax needs anyway, and 2 KB of ROM is the cheaper resource
(docs/uarch.md 3.5).

## 4. mac_unit

### 4.1 Function and interface

ACT x ACT multiply with SACC accumulate: the leaf of the Q.K^T datapath. One
signed Q1.6 x Q1.6 product per enabled cycle, accumulated exactly (no
rounding, no saturation) into a 24-bit Q11.12 register. Ports, from
rtl/mac_unit.sv:

```systemverilog
module mac_unit (
    input  logic               clk,
    input  logic               rst,  // synchronous, active-high
    input  logic               en,   // accept a*b this cycle
    input  logic               clr,  // start new accumulation this cycle
    input  logic signed [ 7:0] a,    // ACT Q1.6
    input  logic signed [ 7:0] b,    // ACT Q1.6
    output logic signed [23:0] acc   // SACC Q11.12
);
```

Control contract (one cycle, all synchronous): rst clears; clr=1 en=1 loads
a*b (a new dot product starts with no dead cycle); clr=1 en=0 clears;
clr=0 en=1 accumulates; clr=0 en=0 holds.

### 4.2 Width derivation summary (normative: docs/uarch.md 3.2)

Shown, not asserted:
- Product: raw p = a_raw * b_raw with scale 2^(6+6) = 2^12. Worst case is
  (-128) * (-128) = 2^14 raw (value 4.0), exact, since integer multiply
  never rounds. 16 bits hold it.
- Sum of D = 16 products: |sacc_raw| <= 16 * 2^14 = 2^18 (value 64). The
  minimum signed width for +2^18 is 20 bits.
- Chosen width 24 (byte aligned, Q11.12), headroom |sum| < 2^23 raw. The
  exact edge of that headroom claim: D * 2^14 <= 2^23 - 1 holds for
  D <= 511; at D = 512 the all-(-128)^2 pattern sums to exactly +2^23, one
  past signed max. Irrelevant at D = 16, but the testbench pokes at exactly
  this corner (section 4.4).

Accumulation is exact: no rounding site, no saturation site; overflow is
impossible by the bound above, and the golden models assert it.

### 4.3 Microarchitecture

The whole module is one combinational next-state block and one flop block,
pasted verbatim from rtl/mac_unit.sv:

```systemverilog
  logic signed [15:0] prod;
  logic signed [23:0] base;
  logic signed [23:0] acc_n;

  // All outputs assigned on all paths: no latches.
  always_comb begin
    prod  = a * b;               // exact 16-bit signed product
    base  = clr ? 24'sd0 : acc;
    acc_n = en ? base + 24'(prod) : base;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      acc <= '0;
    end else begin
      acc <= acc_n;
    end
  end
```

Why this shape: the always_comb assigns every signal on every path (no
inferred latch possible), the clr-before-en ordering encodes the priority
rst > clr > en in two nested selects, and the synchronous active-high reset
matches the project-wide reset style (docs/uarch.md 8.1 naming rules). The
only state is the 24-bit acc register.

Common mistake this design avoids: writing `acc <= acc + prod` guarded by
`if (en)` and separately `if (clr) acc <= prod` invites a priority bug when
both are high; computing base first makes clr+en load-not-add-to-garbage by
construction, which is what enables back-to-back dot products with no dead
cycle.

### 4.4 Verification evidence

`make verify MODULE=mac_unit` exits 0 (lint, sim, coverage, synth-check,
formal) [EVIDENCE: verify-mac_unit].

Simulation (tb/mac_unit/test_mac_unit.py, cocotb under verilator, drive on
RisingEdge, sample on FallingEdge): 4 tests, all passing, independently
re-run by the formal-coverage auditor on two seeds
[EVIDENCE: audit-mac_unit-formal-coverage]:

1. reset_and_directed: reset clears; every control combination checked with
   hand-computed values (load 3 * -5, accumulate -7 * -9, hold under
   changing inputs, clr-without-en clear).
2. dot_products_vs_golden: 200 random D=16 dot products, exactly the golden
   model's SACC inner loop, streamed back to back with clr overlapped on
   d=0 (no dead cycle).
3. extremes_and_width_edge: all corner operand pairs {-128,-1,0,1,127}^2;
   the largest in-spec accumulation, 511 terms of (-128)*(-128), checked
   exact at 511 * 16384; then ONE more term to confirm 24-bit wrap, which
   pins the register at exactly 24 bits (a wider register would not wrap, a
   narrower one would have failed the 511-term check).
4. random_control_fuzz: 2000 cycles of fully random data and control
   checked every cycle against a bit-exact software mirror (catches en/clr
   priority and hold bugs).

Coverage: line coverage 100% [EVIDENCE: audit-mac_unit-formal-coverage];
the raw counter file is tb/mac_unit/coverage.dat (8 of 8 instrumented
points hit).

Synthesis: yosys check reports 0 problems, no $_DLATCH_ cells, netlist
latch-free; independently re-run and countersigned
[EVIDENCE: audit-mac_unit-lint-synth]. Log: build/synth_full.log (the
PROC_DLATCH pass reports "No latch inferred" for prod, base, and acc_n).

Timing (Phase 4 flow, tool estimate in simulation): the sky130-mapped
mac_unit netlist meets the 10 ns target period with +4.101 ns setup slack
(build/sta_mac_unit.log, OpenSTA, tt corner)
[EVIDENCE: phase4-sta].

Formal (formal/mac_unit.sby: BMC, depth 20, smtbmc z3): the FORMAL block in
rtl/mac_unit.sv restates the five-row control contract as immediate
assertions over $past values; sby returned PASS
[EVIDENCE: verify-mac_unit], re-run by the auditor
[EVIDENCE: audit-mac_unit-formal-coverage]. Proof log:
formal/mac_unit/logfile.txt ("DONE (PASS, rc=0)"). The property block,
pasted from rtl/mac_unit.sv:

```systemverilog
  always_ff @(posedge clk) begin
    if (f_past_valid) begin
      if ($past(rst)) begin
        assert (acc == 24'sd0);
      end else if ($past(clr) && !$past(en)) begin
        assert (acc == 24'sd0);
      end else if ($past(clr) && $past(en)) begin
        assert (acc == 24'(16'($past(a) * $past(b))));
      end else if ($past(en)) begin
        assert (acc == 24'($past(acc) + 24'(16'($past(a) * $past(b)))));
      end else begin
        assert (acc == $past(acc));
      end
    end
  end
```

What formal deliberately does NOT prove here: the assertions recompute
$past(a) * $past(b) with the same operator the datapath uses, so the proof
establishes the register/control behavior (reset, clear, load, accumulate,
hold, and their priority) for ALL input sequences to depth 20, not that
SystemVerilog multiplication equals mathematical multiplication. Numerical
correctness against an independent reference is the simulation's job (the
cocotb mirror and the golden-model dot products).

### 4.5 Known gaps (auditor findings, stated honestly)

- The mac_unit testbench RNGs are fixed literals (random.Random(2) and
  random.Random(3)), so the Makefile SEED variable does not change this
  module's random stimulus; the auditor's two-seed re-run therefore
  repeated identical random tests for this module. The finding was
  carried forward and fixed in every later testbench (tb/matmul_tile and
  tb/online_softmax build their RNGs from cocotb.RANDOM_SEED; see the
  tb/matmul_tile/test_matmul_tile.py docstring, which documents this as a
  mandatory carried-forward auditor finding). The gap was noted in the
  audit report [EVIDENCE: audit-mac_unit-formal-coverage].
- BMC depth is 20 cycles; behaviors requiring longer sequences (such as the
  511-term accumulation) are covered by simulation only. The 24-bit
  no-overflow bound is a paper proof (docs/uarch.md 3.2) checked by model
  asserts and the directed 511/512-term tests, not by formal.

## 5. matmul_tile

### 5.1 Function and interface

One 4x4 block of the score matrix S = Q.K^T as a grid of 16 mac_unit
instances. MAC (i, j) accumulates q_i[d] * k_j[d] over the streamed
dimension d = 0..15; each enabled cycle consumes one element from each of
the 4 Q rows (broadcast across grid columns) and each of the 4 K rows
(broadcast down grid rows), so the whole 4x4 block completes in the same
D = 16 cycles as a single dot product. Ports, from rtl/matmul_tile.sv:

```systemverilog
module matmul_tile (
    input  logic         clk,
    input  logic         rst,      // synchronous, active-high
    input  logic         en,       // accept one product per MAC this cycle
    input  logic         clr,      // start a new tile this cycle
    input  logic [ 31:0] q_flat,   // 4 ACT Q1.6 elements, one per Q row
    input  logic [ 31:0] k_flat,   // 4 ACT Q1.6 elements, one per K row
    output logic [383:0] acc_flat  // 16 SACC Q11.12 accumulators, row-major
);
```

Packing convention (little-endian slicing, element 0 in the low bits,
normative in docs/uarch.md 8.1): q_flat[8*i +: 8] is the ACT element of Q
row i; k_flat[8*j +: 8] is the ACT element of K row j;
acc_flat[24*(4*i+j) +: 24] is SACC element (row i, col j), row-major. Flat
packed vectors are used because unpacked-array ports are handled
inconsistently across verilator, iverilog, yosys, sby, and cocotb.

### 5.2 Design decision: output-stationary, not weight-stationary

This is a deliberate, documented deviation from the TPU-style
weight-stationary systolic array in the build sheet's reference language
(docs/uarch.md 8.1):

- On the score path BOTH operands stream: Q and K are per-inference
  activations, so there is no long-lived weight matrix whose residency a
  weight-stationary array would amortize. The precondition for
  weight-stationary winning does not exist here.
- Output-stationary keeps partial sums inside each PE's accumulator:
  no systolic skew registers, no partial-sum forwarding chain, no drain
  sequence. Results are read out in place.
- The already-verified mac_unit clr/en contract implements the entire tile
  with zero additional datapath; any other dataflow would add unverified
  arithmetic or movement logic for no benefit at this size.

The weight-stationary tradeoff (pin one operand, stream the other, pipeline
partial sums; amortizes weight loads when one matrix is reused across a
batch) is documented in docs/uarch.md 8.1 as an interview talking point and
is NOT implemented.

### 5.3 Microarchitecture

The tile is purely structural: no arithmetic outside mac_unit, no counters,
no FSM, no state other than the 16 accumulators (the d-loop counter and all
sequencing belong to attention_top by the binding ownership split in
docs/uarch.md 8.1). The entire body, pasted from rtl/matmul_tile.sv:

```systemverilog
  for (genvar i = 0; i < 4; i++) begin : g_row
    for (genvar j = 0; j < 4; j++) begin : g_col
      logic signed [23:0] acc_ij;

      mac_unit u_mac (
          .clk(clk),
          .rst(rst),
          .en (en),
          .clr(clr),
          .a  (signed'(q_flat[8*i+:8])),
          .b  (signed'(k_flat[8*j+:8])),
          .acc(acc_ij)
      );

      assign acc_flat[24*(4*i+j)+:24] = acc_ij;
    end
  end
```

Flop count derivation: 16 mac_units x one 24-bit accumulator each =
16 * 24 = 384 flip-flops, and the auditor's independent synthesis re-run
reports exactly 384 FFs in the latch-free netlist
[EVIDENCE: audit-matmul_tile-lint-synth]. The signed'() casts matter: the
+: slices of the unsigned flat buses would otherwise zero-extend and break
negative operands; the auditor verified packing and signedness against
docs/uarch.md 8.1 [EVIDENCE: audit-matmul_tile-lint-synth].

Common mistake this tile's testbench targets: a transposed wiring bug
(swapping the i/j broadcast or the acc_flat packing) is invisible to any
test whose expected S block is symmetric, because S[i][j] = S[j][i] there.
See broadcast_independence below.

### 5.4 Verification evidence

`make verify MODULE=matmul_tile` exits 0 [EVIDENCE: verify-matmul_tile].

Simulation (tb/matmul_tile/test_matmul_tile.py): 6 tests, all passing on two
genuinely different seeds (the seed plumbing fix from the mac_unit finding:
RNGs derive from cocotb.RANDOM_SEED, so SEED=1 vs SEED=7 provably changes
stimulus) [EVIDENCE: audit-matmul_tile-formal-coverage]:

1. reset_and_directed: reset clears all 16; a hand-computed block where
   dot(Q_i, K_j) = 16*(i+1)*(j+1); hold; clr-without-en clear.
2. golden_block_streaming: 100 random 4x4x16 tiles streamed back to back
   with clr overlapped on d=0, full 16-element compare vs the golden dot
   products every trial.
3. broadcast_independence: a directed pattern where every Q row and K row
   is a distinct shape and the resulting S block is verified asymmetric, so
   a swapped or transposed (i, j) wiring bug would read back S[j][i] where
   S[i][j] is expected and fail the elementwise compare. Its docstring
   asserts the asymmetry precondition so the test cannot silently lose its
   bug-catching power.
4. extremes_and_width_edges: the all-(-128) block (every accumulator at the
   max positive product sum 16 * 16384 = 262144), a mixed +127/-128 block,
   the 511-term in-spec negative accumulation (511 * (-16256) = -8306816,
   inside [-2^23, 2^23-1]), and the 24-bit wrap crossing. The crossing
   count is itself derived in the test: reaching magnitude 2^23 = 8388608
   with per-cycle product 16256 needs ceil(8388608 / 16256) = 517 terms
   (516 * 16256 = 8388096 is still in bound), so the test streams 6 extra
   cycles past the 511-term point, and the comment records that a
   task-prompt suggestion of 2 cycles was wrong rather than weakening the
   check to match it.
5. directed_reset_mid_tile: rst asserted at d=7 of a streamed tile clears
   all 16 accumulators synchronously; a full clean tile afterward computes
   correctly.
6. random_control_fuzz: 2000 cycles of fully random rst/en/clr/q/k against
   a 16-accumulator mirror, checked every cycle.

Coverage: tile line coverage 100%
[EVIDENCE: audit-matmul_tile-formal-coverage]; raw counters in
tb/matmul_tile/coverage.dat.

Synthesis: multi-file lint clean, yosys check 0 problems, no $_DLATCH_,
netlist 384 FF latch-free [EVIDENCE: audit-matmul_tile-lint-synth].

Timing (Phase 4 flow, tool estimate in simulation): the sky130-mapped
matmul_tile netlist meets the 10 ns target period with +4.101 ns setup
slack (build/sta_matmul_tile.log, OpenSTA, tt corner)
[EVIDENCE: phase4-sta].

Formal (formal/matmul_tile.sby: BMC, depth 5, smtbmc z3): PASS, audited
non-vacuous by SMT2 inspection
[EVIDENCE: audit-matmul_tile-formal-coverage]. Proof log:
formal/matmul_tile/logfile.txt ("DONE (PASS, rc=0)", 1 minute 21 seconds of
solver time). This proof uses a deliberate, documented reduction, pasted
from formal/matmul_tile.sby:

```
[script]
read_verilog -sv -formal -DFORMAL mac_unit.sv matmul_tile.sv
prep -top matmul_tile
chformal -assert -remove mac_unit
```

What the chformal reduction means, exactly: the inner mac_unit assertions
are stripped from the tile-level proof because that contract is already
proven standalone at depth 20 (section 4.4); re-proving 16 replicated
copies of the identical contract inside the tile BMC is redundant solver
load with no additional coverage. What remains PROVEN at tile level, for
all input sequences to depth 5: reset drives all 384 acc_flat bits to 0;
clr-without-en drives all 384 bits to 0; hold leaves acc_flat unchanged;
and one representative datapath element, (0,0), recomputes both the
clr-and-en load and the accumulate against the exact q*k product. What is
deliberately NOT covered by formal after this reduction: the datapath of
the other 15 elements. That is exactly what the cocotb testbench covers
exhaustively instead (all 16 elements compared on every trial of every
test, including the asymmetric broadcast_independence pattern built to
catch the transposed-wiring bug that a single-element formal check cannot
see). The auditor re-ran the proof, inspected the generated SMT2 to confirm
the remaining assertions are non-vacuous, and countersigned the reduction
as justified [EVIDENCE: audit-matmul_tile-formal-coverage].

### 5.5 Known gaps

- Formal covers the shared-control glue over the full 384-bit bus plus one
  spot-checked element; per-element datapath assurance for 15 of 16
  elements is simulation-only (by design, documented in the .sby file and
  countersigned [EVIDENCE: audit-matmul_tile-formal-coverage]).
- BMC depth 5 covers the control contract (every assertion is a one-cycle
  relation over $past); multi-hundred-cycle accumulations are simulation
  territory, as with mac_unit.

## 6. online_softmax

### 6.1 Function and interface

The per-row online-softmax (m, l) state machine of docs/uarch.md section 6,
EXCLUDING the NUM path and the final division (both belong to
attention_top). Per accepted score s it computes:

```
m_new = max(m, s)
r     = lut[ idx(m - m_new) ]     rescale factor, WGT UQ1.15
w     = lut[ idx(s - m_new) ]     this element's weight, WGT UQ1.15
l     <= rshr(l * r, 15) + w      DEN UQ9.15 (rounding site 3)
m     <= m_new
```

Since Phase 4 the module carries one parameter, PIPE_ROM (docs/uarch.md
8.2.1). PIPE_ROM = 0, the default and the configuration attention_top
instantiates, is the normative single-cycle recurrence documented in this
section; the lint-synth auditor confirmed the default generate branch
byte-identical to the previously audited arithmetic
[EVIDENCE: audit-online_softmax-pipe-lint-synth]. PIPE_ROM = 1 is the
registered-ROM timing variant, documented in section 9. Ports, from
rtl/online_softmax.sv:

```systemverilog
module online_softmax #(
    parameter bit PIPE_ROM = 1'b0  // 0: latency-1 (normative); 1: uarch 8.2.1
) (
    input  logic               clk,
    input  logic               rst,        // synchronous, active-high
    input  logic               in_valid,   // accept score s this cycle
    input  logic               row_start,  // with in_valid: first element of a row
    input  logic signed [15:0] s,          // SCORE Q5.10
    output logic        [15:0] w,          // WGT UQ1.15, registered
    output logic        [15:0] r,          // WGT UQ1.15, registered
    output logic               out_valid,  // w, r valid (1 + PIPE_ROM cycles after accepted s)
    output logic        [23:0] l,          // DEN UQ9.15, current denominator
    output logic signed [15:0] m           // SCORE Q5.10, current running max
);
```

Timing contract (PIPE_ROM = 0): single-cycle recurrence, one element per
cycle, no backpressure; (m, l) update on the edge that consumes s and w, r,
out_valid register on the same edge, so during an out_valid cycle the
visible l already includes the element that (w, r) describe. Rows may be
issued back to back with no dead cycle (row_start with in_valid overrides
the stale state). The full cycle diagram is in docs/uarch.md 8.2 and is
reproduced in the RTL header comment.

### 6.2 Width and rounding derivation summary (normative: docs/uarch.md 3.3 to 3.6)

- SCORE Q5.10: |s| <= 4 * sqrt(D) = 16 for D = 16, needing 5 integer bits
  (Q5 spans [-32, 32)); 1 + 5 + 10 = 16 bits. The score conversion is ONE
  rounding step, s_raw = sat16((sacc_raw + 8) >> 4): scale 2^12 to 2^10 is
  >>2, divide by sqrt(16) = 4 is another >>2, combined >>4 with a single
  add-half (+8 = 2^3). Saturation is defensive only at D = 16: the max
  |s_raw| = (2^18 + 8) >> 4 = 2^14 = 16384 < 32767 (docs/uarch.md 3.3).
  This site lives UPSTREAM of this module (score-scale stage, implemented
  in attention_top, section 7.3); the module consumes s already in SCORE
  format and contains no saturation.
- WGT UQ1.15: exp(x) for x <= 0 lies in (0, 1], and 1.0 must be exact
  because the running-max element always has weight exp(0) = 1; raw 32768 =
  0x8000 needs 16 unsigned bits with 15 fractional bits (docs/uarch.md 3.4).
- LUT index: the differences m - m_new and s - m_new are computed in 17
  bits BEFORE the clamp because two 16-bit SCOREs can differ by up to
  65535; then clamp to -16384 (-16.0), then idx = min((-d_c + 8) >> 4,
  1023), round-half-up to the 2^-6 grid (docs/uarch.md 3.5). The two
  functional clamps of the whole design (diff clamp, index clamp) both
  live in this module.
- DEN UQ9.15 in 24 bits: the no-overflow proof is BY INDUCTION including
  the rounding term (docs/uarch.md 3.6): rshr(l * r, 15) <= l for any
  r <= 2^15 because l * r + 2^14 < (l + 1) * 2^15, so after j terms
  l_raw <= j * 2^15, hence l <= 2^23 at N_MAX = 256, inside 24 bits with
  the rounding bias consuming zero margin. The lower bound l_raw >= 2^15
  (the max element contributes exp(0), and identity rescales never shrink
  it) is what guarantees the attention_top divider a nonzero denominator.
- Error placement: LUT index rounding bounds the per-weight relative error
  at e^(2^-7) - 1 = 0.784%; score quantization contributes 0.098% and
  entry quantization 0.0015%, so total eps0 <= 0.89% and the output bound
  is 2 * eps0 * (v_max - v_min) <= 4.6 LSB of Q1.6, inside the 6 LSB gate
  (docs/uarch.md section 7). The bound is loose worst-case; the recorded
  cross-check worst deviation is 0.77 LSB (section 3.2).

### 6.3 Microarchitecture (PIPE_ROM = 0, the default)

Stage-1 combinational logic (base mux, running max, diffs, index math, both
ROM lookups) is shared by both configurations; the latency-1 l update and
register block live in the g_lat1 generate branch. Both pasted verbatim
from rtl/online_softmax.sv:

```systemverilog
  // All signals assigned unconditionally: no latches.
  always_comb begin
    m_base = row_start ? MInit : m;
    m_n    = (m_base >= s) ? m_base : s;
    diff_m = 17'(m_base) - 17'(m_n);
    diff_s = 17'(s) - 17'(m_n);
    idxp_r = lut_index_pre(diff_m);
    idxp_w = lut_index_pre(diff_s);
    idx_r  = (idxp_r > 11'd1023) ? 10'd1023 : idxp_r[9:0];
    idx_w  = (idxp_w > 11'd1023) ? 10'd1023 : idxp_w[9:0];
    r_n    = exp_lut_rom(idx_r);
    w_n    = exp_lut_rom(idx_w);
  end
```

```systemverilog
  if (PIPE_ROM == 1'b0) begin : g_lat1
    // Normative latency-1 configuration (uarch.md 8.2): the whole recurrence
    // closes in the cycle that consumes s.
    logic [23:0] l_base;
    logic [39:0] lr_prod;  // l * r, 24u x 16u, never registered
    logic [40:0] lr_rnd;  // + 2^14 round-half-up bias
    logic [23:0] l_resc;  // rshr(l * r, 15)
    logic [23:0] l_n;

    always_comb begin
      l_base  = row_start ? 24'd0 : l;
      // Rounding site 3: l = rshr(l * r, 15) + w. Bits above 23 of the
      // shifted value are provably zero for spec-compliant rows (l <= 2^23
      // by the 3.6 induction, r <= 2^15), and l_resc + w < 2^24 likewise;
      // DEN carries no saturation by policy (section 5), so the casts
      // truncate nothing.
      lr_prod = l_base * r_n;
      lr_rnd  = {1'b0, lr_prod} + 41'd16384;
      l_resc  = 24'(lr_rnd >> 15);
      l_n     = l_resc + 24'(w_n);
    end

    always_ff @(posedge clk) begin
      if (rst) begin
        m         <= MInit;
        l         <= 24'd0;
        w         <= 16'd0;
        r         <= 16'd0;
        out_valid <= 1'b0;
      end else begin
        out_valid <= in_valid;
        if (in_valid) begin
          m <= m_n;
          l <= l_n;
          w <= w_n;
          r <= r_n;
        end
      end
    end
  end
```

The index helper, also verbatim (note the pre-clamp value is kept visible so
the formal block can assert its range):

```systemverilog
  function automatic logic [10:0] lut_index_pre(input logic signed [16:0] d);
    logic signed [16:0] d_c;
    logic [14:0] nd;
    begin
      d_c = (d < -17'sd16384) ? -17'sd16384 : d;  // diff clamp (section 5)
      nd = 15'(-d_c);  // in [0, 16384], 15 bits
      lut_index_pre = 11'((nd + 15'd8) >> 4);  // rounding site 2
    end
  endfunction
```

Flop count derivation (default configuration): m (16) + l (24) + w (16) +
r (16) + out_valid (1) = 73 flip-flops. Both the original audit and the
post-parameterization re-audit report exactly 73 FFs in the latch-free
default netlist [EVIDENCE: audit-online_softmax-lint-synth],
[EVIDENCE: audit-online_softmax-pipe-lint-synth]. The l * r intermediate is
the 40-bit (24u x 16u) product of docs/uarch.md section 2 and is never
registered. The two ROM lookups per cycle (w and r) are two combinational
muxes of the same constant table.

Two identities the design relies on (docs/uarch.md 6.1), both tested:
1. r = 0x8000 (max unchanged) is an EXACT identity: rshr(x * 32768, 15) = x
   for any x, because adding 2^14 to x * 2^15 never reaches the next
   multiple of 2^15. No drift accumulates across steps without a max update.
2. First element: row_start bases the step at (m = -32768, l = 0); the
   rescale diff clamps into the LUT zero tail so r = 0, w = lut[0] =
   0x8000, and the post-step state is exactly (m = s0, l = 32768).

Common mistake box, from a real test-authoring bug documented in the TB:
when a score far below the running max is driven, it is diff_s (feeding w,
the element's own weight) that clamps to the zero tail, while diff_m stays
0 so r remains the exact identity 0x8000. An early version of the
directed_sequences test asserted r == 0 there, clamping the wrong one of
the two diffs, and failed; the corrected pairing is now asserted and the
mistake is documented in the test comment (tb/online_softmax/
test_online_softmax.py, directed_sequences).

### 6.4 Verification evidence

`make verify MODULE=online_softmax` exits 0
[EVIDENCE: verify-online_softmax]. The module was verified and dual
countersigned first in latency-1-only form
[EVIDENCE: audit-online_softmax-lint-synth],
[EVIDENCE: audit-online_softmax-formal-coverage], then re-audited in full by
both auditors after the Phase 4 PIPE_ROM parameterization
[EVIDENCE: audit-online_softmax-pipe-lint-synth],
[EVIDENCE: audit-online_softmax-pipe-formal-coverage].

Simulation, default configuration (tb/online_softmax/test_online_softmax.py
plus the Phase 3 coverage module test_softmax_coverage.py): 9 tests, all
passing on two seeds, with 52/52 reachable functional bins hit and line
coverage 99.3% against the 90% gate
[EVIDENCE: audit-online_softmax-pipe-formal-coverage]. The golden reference
is imported DIRECTLY from model/attn.py (lut_index, rshr, gen_exp_lut), not
re-derived, so the TB cannot drift from the model. The seven
test_online_softmax.py tests:

1. reset_and_first_element_identity: post-reset state (m = -32768, l = 0,
   out_valid = 0); identity 2 checked for nine different s0 values,
   asserting m == s0, l == 32768, w == 32768 independent of s0.
2. rom_lookup_spot_checks: with the max pinned at m = 0, scores that hit
   exact LUT indices 0, 1, 64, 128, 256, 443, 512, 709, 710, 1023 (the
   docs/uarch.md 3.5 anchor entries plus the zero-tail boundary at
   709/710), checking the RTL w output against lut[idx] end to end.
3. rom_full_sweep: an exhaustive sweep of ALL 1024 LUT indices, checking w
   against lut[idx] at each one. This test exists because verilator
   instruments each generated case-assignment line as a separate coverage
   point; the 10-point spot check left 1014 of them unexercised, a real
   coverage hole found by scripts/check_coverage.py (85.3% at the time, all
   zero-hit points inside exp_lut.svh, per the test docstring), closed by
   sweeping rather than by weakening the gate.
4. directed_sequences: strictly increasing scores (a genuine rescale,
   r != 0x8000, every step after the first); strictly decreasing scores
   (identity 1: r == 0x8000 exactly on every later step and l equal to the
   exact sum of all w values with zero drift); constant scores; the domain
   clamp (w hits the zero tail while r stays identity, see the common
   mistake box); SCORE extremes at row start.
5. full_row_golden_compare: 100 random rows of length 1..64, idle gaps
   randomly interleaved, some rows back to back with no dead cycle,
   comparing (m, l, w, r, out_valid) against the mirror EVERY cycle, not
   just at row boundaries.
6. realistic_flow_vs_attn_trace: two random N=16 attention cases whose real
   score streams are produced by model/attn.py itself (sacc to s per
   docs/uarch.md 3.3), fed row by row; the final l per row is checked
   against attn_fixed's trace hook, the same golden model that gates
   attention_top.
7. random_control_fuzz: 2000 cycles of random in_valid/row_start/s against
   the mirror, checked every cycle, including hold behavior when
   in_valid = 0; row length capped at 60 to stay inside the N <= 256 DEN
   bound the width proof relies on.

The two Phase 3 tests (directed_den_worst_case, constrained_random_coverage)
and the functional coverage model are documented in section 8; the eight
PIPE_ROM = 1 tests in section 9.2.

ROM equivalence is additionally checked at TB import time, before any
simulation: exp_lut.hex vs exp_lut.svh vs gen_exp_lut() entry for entry,
plus the sha256 pin (section 3.3).

Coverage honesty note: in the original (pre-parameter) audit the sole missed
line-coverage point was investigated and verified UNREACHABLE: the generated
default arm of the exp_lut_rom case statement, which a 10-bit index that is
fully enumerated by 1024 case arms can never select
[EVIDENCE: audit-online_softmax-formal-coverage]. The post-parameterization
re-audit reports 99.3% line coverage for the default elaboration against the
90% gate [EVIDENCE: audit-online_softmax-pipe-formal-coverage]. Raw
counters: tb/online_softmax/coverage.dat (default) and
coverage_pipe_rom1.dat (PIPE_ROM = 1).

Synthesis: lint clean in BOTH elaborations, yosys check 0 problems in both,
no $_DLATCH_, netlists latch-free (73 FF default, 107 FF PIPE_ROM = 1,
counts matching the spec), arithmetic verified against docs/uarch.md
sections 6 and 3.5, generated ROM confirmed diff-identical to the emitter
[EVIDENCE: audit-online_softmax-pipe-lint-synth].

Formal (formal/online_softmax.sby): since Phase 4 the proof has two tasks,
both required green, both BMC depth 20 with smtbmc z3, both PASS and audited
non-vacuous [EVIDENCE: audit-online_softmax-pipe-formal-coverage]. Task p0
(default elaboration, 18 assertions) proves, for every input sequence to
depth 20: the clamp facts (diff_m <= 0, diff_s <= 0, pre-clamp indices
<= 1024, final indices <= 1023, as combinational assertions); reset state
(m = -32768, l = 0, out_valid = 0); hold when in_valid was low (m, l, w, r
unchanged and no stale out_valid pulse); out_valid rises exactly one cycle
after each accepted element; on a row_start step m becomes exactly the
incoming s; otherwise m equals the exact max recurrence (the Phase 3
property, section 8.2, which strictly subsumes the retained monotonicity
assert). Task p1 (PIPE_ROM = 1 via chparam, 17 assertions) is documented in
section 9.3. Proof logs: formal/online_softmax_p0/logfile.txt and
formal/online_softmax_p1/logfile.txt ("DONE (PASS, rc=0)").

The formal-is-a-subset split, stated exactly (from the .sby header and
CLAUDE.md): the BMC transition relation CONTAINS the 1024-entry ROM
function and the 24u x 16u multiply (they feed the asserted registers), but
no property asserts ROM contents or product values, because an open-source
BMC flow proving a 40-bit multiply and a 1024-way ROM functionally correct
is exactly the proof this toolchain cannot do in reasonable time. Those
checks are deliberately pushed to cocotb: LUT entry-for-entry equivalence
(rom_full_sweep plus the import-time triple check), the full recurrence
against the model/attn.py mirror on every cycle, and the DEN bound over
long random rows.

### 6.5 Known gaps

- Formal does not prove ROM contents, multiplier correctness, or the DEN
  induction bound; simulation carries those (see the split above). This is
  a documented toolchain-driven scope decision, not an oversight.
- Line coverage is 99.3% for the default elaboration, not 100%; the known
  unreachable point class (the generated ROM default arm) was verified dead
  by construction in the original audit
  [EVIDENCE: audit-online_softmax-formal-coverage].
- Timing: the single-cycle path diff -> clamp -> index -> ROM ->
  (l * r multiply) -> rshr -> add is, as predicted in docs/uarch.md 8.2,
  the critical path of the whole design. Phase 4 measured it: the default
  configuration does NOT meet the 10 ns target (slack -15.574 ns,
  build/sta_online_softmax.log) and the pipelined variant does not either
  (slack -2.664 ns, build/sta_online_softmax_pipe1.log); the met periods
  are 26 ns and 13 ns respectively. Full numbers and the honest framing in
  section 9.4 [EVIDENCE: phase4-sta].

## 7. attention_top (Phase 2 integration)

### 7.1 Function and interface

attention_top stitches matmul_tile and online_softmax, both instantiated
UNMODIFIED, into the full streaming attention recurrence of docs/uarch.md
section 6 for N = n_len rows of self-attention (Q, K, V all n_len x D=16,
n_len a multiple of 4 in [4, 64]). It owns everything the leaf modules do
not: the Q/K/V/output memories, the sequencing FSM, the score conversion
(rounding site 1), the NUM accumulators (rounding site 4), and the output
divider bank (rounding site 5). Normative spec: docs/uarch.md 8.3.
`make verify MODULE=attention_top` exits 0, and both auditors countersigned
[EVIDENCE: verify-attention_top], [EVIDENCE: audit-attention_top-lint-synth],
[EVIDENCE: audit-attention_top-formal-coverage]. Ports, pasted verbatim from
rtl/attention_top.sv:

```systemverilog
module attention_top (
    input  logic        clk,
    input  logic        rst,        // synchronous, active-high

    // Load port: shared byte-granular synchronous write into Q/K/V RAMs.
    input  logic [ 1:0] sel,        // 0=Q, 1=K, 2=V, 3=unused (no write)
    input  logic [ 9:0] addr,       // {row[5:0], col[3:0]}
    input  logic [ 7:0] wdata,      // ACT Q1.6
    input  logic        we,

    // Config + control.
    // verilator lint_off UNUSEDSIGNAL
    // n_len[1:0] is never read: the 8.3 contract requires n_len to be a
    // multiple of 4, so only n_len[6:2] (the block/group count) matters.
    input  logic [ 6:0] n_len,      // multiple of 4, 4 <= n_len <= 64
    // verilator lint_on UNUSEDSIGNAL
    input  logic        start,      // pulse; accepted only when busy = 0
    output logic        busy,
    output logic        done,       // one-cycle pulse, the cycle busy falls

    // Output buffer: registered synchronous read port.
    input  logic [ 9:0] rd_addr,    // {row[5:0], col[3:0]}
    output logic [ 7:0] rd_data,    // ACT Q1.6, valid one cycle after rd_addr

    // Phase 2 benchmark counter.
    output logic [31:0] cycle_count
);
```

Protocol: load Q, K, V through the byte write port, pulse start, poll busy
or wait for the done pulse, read the result back through rd_addr/rd_data
(registered, one cycle of read latency), and read cycle_count for the exact
run length.

### 7.2 Dataflow: 4-row groups, software-pipelined drain

Query rows are processed in groups of 4, matching the tile's 4x4 shape. Per
group, key/value blocks of 4 stream through matmul_tile one D=16-cycle block
at a time; while block kb computes, block kb-1's already-finished 4x4 SACC
block is drained into 4 online_softmax instances (one per query row, the
"lanes"), one score per lane every 4 cycles, round-robin over the block's
16-cycle period. This is a software-pipelined double buffer: matmul_tile's
own accumulator IS one buffer; a captured 384-bit register (drain_buf) is
the other. The FlashAttention carry (the running (m, l) across key blocks)
is exactly online_softmax's own state persisting across the nblk drains of
one row group; attention_top only sequences which SACC block feeds which
lane when. The round-robin addressing, pasted from rtl/attention_top.sv:

```systemverilog
  wire [1:0] lane      = t[1:0];
  wire [1:0] key_local = t[3:2];

  logic       drain_en;
  logic [3:0] drain_blk;   // block index whose scores are being drained now

  always_comb begin
    drain_en  = ((state == S_COMPUTE) && (kb != 4'd0)) || (state == S_DRAIN_LAST);
    drain_blk = (state == S_DRAIN_LAST) ? (nblk_m1) : (kb - 4'd1);
  end

  wire [5:0] drain_v_row = {drain_blk, key_local};

  logic       row_start_val;
  always_comb row_start_val = drain_en && (key_local == 2'd0) && (drain_blk == 4'd0);
```

lane = t mod 4 and key_local = t div 4 preserve per-lane ascending key order
(lane L sees key_local 0, 1, 2, 3 at cycles L, L+4, L+8, L+12), which the
online-softmax streaming contract requires.

The capture subtlety (the one thing that is easy to get wrong by one cycle):
at the edge ending a block's t=15 cycle, acc_flat is ANOTHER module's
registered output, and a same-edge register-to-register read sees the
PRE-edge value by nonblocking-assignment semantics, which at that instant
holds only the sum through d=0..14. Rather than shift the whole round-robin
schedule by a cycle, attention_top computes the missing d=15 outer product
combinationally from the same cycle's own q_flat/k_flat (which carry exactly
the d=15 operands) and adds it before registering. Pasted verbatim:

```systemverilog
  logic [383:0] drain_buf;
  logic [383:0] drain_buf_next;

  for (genvar cri = 0; cri < 4; cri++) begin : g_cap_row
    for (genvar crj = 0; crj < 4; crj++) begin : g_cap_col
      assign drain_buf_next[24*(4*cri+crj)+:24] =
          24'(signed'(acc_flat[24*(4*cri+crj)+:24]) +
              24'(signed'(q_flat[8*cri+:8]) * signed'(k_flat[8*crj+:8])));
    end
  end

  always_ff @(posedge clk) begin
    if (rst) drain_buf <= '0;
    else if ((state == S_COMPUTE) && (t == 4'd15)) drain_buf <= drain_buf_next;
  end
```

### 7.3 Score conversion and the NUM (PV) path

Score conversion (rounding site 1, docs/uarch.md 3.3) happens at drain time,
combinationally, once per cycle, from whichever (lane, key_local) element of
drain_buf is addressed that cycle; only one element converts per cycle
(matching one online_softmax accept per cycle), so no 16-wide SCORE buffer
exists. Pasted verbatim:

```systemverilog
  wire [3:0] drain_elem_idx = {lane, key_local};
  wire signed [23:0] drain_sacc = drain_buf[24*drain_elem_idx+:24];

  logic signed [24:0] s_wide;
  logic signed [24:0] s_shift;
  logic signed [15:0] s_conv;

  always_comb begin
    s_wide  = 25'(signed'(drain_sacc)) + 25'sd8;
    s_shift = s_wide >>> 4;
    if (s_shift > 25'sd32767) s_conv = 16'sd32767;
    else if (s_shift < -25'sd32768) s_conv = -16'sd32768;
    else s_conv = s_shift[15:0];
  end
```

This is sat16((sacc + 8) >>> 4): the 2^12 to 2^10 rescale (>>2) and the
divide by sqrt(16) = 4 (another >>2) fused into one >>4 with a single
round-half-up bias of +8 = 2^3, saturation defensive only at D = 16
(section 6.2 derivation).

PV (numerator) path: on lane L's out_valid (one cycle after in_valid, per
online_softmax's own contract), lane L's 16-wide NUM bank updates in that
one cycle, k-parallel. Because round-robin guarantees at most one lane fires
out_valid per cycle, ONE shared 16-wide rescale-multiply-add datapath
suffices; row_start travels from the in_valid cycle to the out_valid cycle
in a one-cycle pipeline register per lane (row_start_d), mirroring
online_softmax's internal row_start-to-l_base alignment, so a lane's NUM
bank rebases to 0 on a row group's first element instead of accumulating the
previous group's data. The per-(lane, k) update, pasted verbatim (from the
g_num_lane/g_num_k generate in rtl/attention_top.sv):

```systemverilog
      // rshr(acc_base * r, 15): 48-bit signed product (3.7/6.1), round-
      // half-up bias then arithmetic shift; only the low 32 bits of the
      // shifted value are kept (32'() cast), matching online_softmax's own
      // l_resc truncation style (8.2) and trusted by the same 3.7 bound.
      always_comb begin
        acc_base = row_start_d[gL2] ? 32'sd0 : acc_num[gL2][gK];
        ar_full  = 49'(signed'(acc_base) * signed'({1'b0, lane_r[gL2]}));
        ar_rnd   = ar_full + 49'sd16384;
        wv_prod  = 24'(signed'({1'b0, lane_w[gL2]}) * signed'(v_row_reg[8*gK+:8]));
        if (lane_out_valid[gL2]) acc_next = 32'(ar_rnd >>> 15) + 32'(wv_prod);
        else acc_next = acc_num[gL2][gK];
      end

      always_ff @(posedge clk) begin
        if (rst) acc_num[gL2][gK] <= '0;
        else acc_num[gL2][gK] <= acc_next;
      end
```

v_row_reg is the V RAM's own registered read output; its read address is
presented on the in_valid cycle, so the RAM's one-cycle synchronous read
latency lands the correct V row exactly on the out_valid cycle (section
7.5). The acc*r intermediate is 48-bit signed (32s x 16u) with the same
round-half-up bias and arithmetic shift as online_softmax's l path so a
negative acc*r floors correctly (docs/uarch.md 3.7, 6.1); the NUM width
proof (3.7 induction) makes the 32-bit truncation lossless, and the models
assert the bound.

### 7.4 Divider bank (rounding site 5)

After a row group's last drain the group's (acc_num[L][*], lane_l[L]) are
stable, so the four rows divide sequentially through a 16-wide bank of
serial restoring dividers (one per output column k, identical shared
control). The algorithm is exactly docs/uarch.md 3.8's round-half-up
division divr(num, den) = floor((2*num + den) / (2*den)):

- A = 2*num + den (34-bit signed; |A| fits 33 bits by the 3.7/3.6 bounds),
  B = 2*den (25-bit unsigned, shared across the 16 k dividers of a row
  since l is per-row, not per-k).
- Load |A| and its sign (1 cycle), then 33 shift-subtract restoring
  iterations (one absA bit per cycle into a 25-bit remainder, subtract B
  when the 26-bit trial value is >= B, shift the quotient bit in), then a
  write cycle. Quotient and remainder are exact after iteration 33.
- Sign correction converts the unsigned quotient to the floor of the signed
  division, then sat8 produces the ACT output. Pasted verbatim from the
  g_div generate in rtl/attention_top.sv:

```systemverilog
      q_signed = sign_a_reg ? -(34'(qt_reg) + (rem_reg != 25'd0 ? 34'sd1 : 34'sd0)) : 34'(qt_reg);
      q_sat_in = q_signed;
      if (q_sat_in > 34'sd127) out_raw = 8'sd127;
      else if (q_sat_in < -34'sd128) out_raw = -8'sd128;
      else out_raw = q_sat_in[7:0];
```

The `-(qt + (rem != 0))` term is the floor conversion: for a negative exact
quotient the truncating restoring result must be decremented by one exactly
when the remainder is nonzero, which is the floordiv identity the C++ model
uses (section 3.1); divide-by-zero cannot occur because l_raw >= 2^15
(section 6.2).

Per-row timing derivation: 1 load + 33 iterate + 1 write = 35 cycles/row,
4 rows sequential = 140 cycles/group. The divide phase is deliberately NOT
overlapped with the next group's compute (correctness first); overlapping it
with the next group's block-0 compute is a documented future optimization
(docs/uarch.md 8.3), not implemented.

### 7.5 BRAM-inferable memory conversion

The original attention_top stored Q/K/V/out as unpacked register arrays
(logic [7:0] q_mem[64][16] and friends). That version was functionally
correct but synthesized terribly: yosys formed ZERO $mem_v2 memory cells
(the arrays never became memory objects at all; per-bit register names like
q_mem[1023] confirmed it), producing roughly 32k flip-flops of storage plus
about 72k $eq cells of combinational address decode, 5m23s wall / 4.77 GB
peak for a full synth, and about 60 s of sby time. The memories were
rewritten into the canonical single-port synchronous-RAM inference idiom:
one write port and one registered read port per memory, runtime-indexed, no
per-element genvar write unrolling, and NO reset term on any RAM contents
(an if (rst) branch touching RAM contents is exactly what blocks single-port
BRAM inference). Measured results, from the evidence row
[EVIDENCE: bram-conversion-attention_top]:

| Metric | register arrays | BRAM-pattern | 
|--------|-----------------|--------------|
| attention_top $mem_v2 cells (yosys memory -nomap) | 0 | 4 |
| generic-synth DFF estimate | 37380 | 37548 |
| full yosys synth | 5m23s wall / 4.77 GB | 1m15s wall / 1.25 GB |
| sby BMC depth 10 | about 60 s | 2.8 s |
| behavior | baseline | bit-identical (6/6 tests x 3 seeds, cycles.txt unchanged, verification engineer confirmed) |

(The generic-synth DFF count RISES slightly because generic mapping flattens
RAM to FFs either way; the 4 $mem_v2 cells at the memory stage are the
inference-ready signal a BRAM-aware backend consumes, not the generic FF
count.) The lint-synth auditor independently confirmed the four memories and
their geometries: q_word_mem 256x32, k_word_mem 256x32, v_mem 64x128,
out_mem 64x128, all WR_PORTS=1 RD_PORTS=1
[EVIDENCE: audit-attention_top-lint-synth].

The geometry choices (docs/uarch.md 8.3):
- Q and K are COLUMN-MAJOR, word-packed 4 ACT bytes/word, word address
  {group[3:0], col[3:0]}: one word IS q_flat/k_flat in matmul_tile's own
  little-endian lane packing, so a single synchronous read per cycle feeds
  the tile with no multi-row combinational decode. The byte-granular load
  port writes one of the 4 byte lanes of a word (byte lane = row[1:0]), the
  standard partial-word BRAM write.
- V is ROW-MAJOR, 16 bytes/word (one V row = one word), matching the drain
  path's whole-row access; out_mem likewise, written whole by the divider
  bank and read back byte-granular through the registered rd_addr port.

Because a synchronous RAM read is one cycle late, the Q/K read address is
PREFETCHED: the FSM's combinational next-state values (rg_n/kb_n/t_n, the
same case structure as the sequential update, lifted out) drive the read
port this cycle, so the registered RAM output lands next cycle exactly the
value a combinational read of the current (rg, kb, t) used to give. Zero
added latency; the cycle_count formula is unchanged and was re-verified
bit-exactly by the existing testbench after the conversion. The Q memory
block, pasted verbatim as the canonical idiom:

```systemverilog
  wire [7:0] q_raddr = {rg_n, t_n};
  wire [7:0] k_raddr = {kb_n, t_n};

  logic [31:0] q_flat;
  logic [31:0] k_flat;

  always_ff @(posedge clk) begin
    if (we_q) q_word_mem[qk_waddr][8*qk_byte_lane+:8] <= wdata;
    if (rst) q_flat <= '0;
    else q_flat <= q_word_mem[q_raddr];
  end
```

The V read needs no prefetch trick: its address (drain_v_row) is the same
combinational signal that gates online_softmax's in_valid, and the RAM's
one-cycle latency lands the row on the out_valid cycle, replacing the
hand-built per-lane V-row pipeline register the register-array version
needed. Correctness without a contents reset relies on the load-before-use
protocol: the FSM only indexes rows 0..n_len-1 and every testbench writes
the full matrices before pulsing start; the ordinary control and pipeline
registers DERIVED from RAM reads (q_flat, k_flat, v_row_reg, rd_data) still
carry the project-standard synchronous reset.

### 7.6 FSM and the cycle-count formula

Four states (docs/uarch.md 8.3): S_IDLE (busy = 0; start latches
nblk_reg = n_len[6:2] and zeroes the counters), S_COMPUTE (16 cycles per
key/value block: the tile streams block kb with clr at t=0; concurrently
drains block kb-1 if kb != 0; captures drain_buf at t=15), S_DRAIN_LAST (16
more cycles draining the final block that had no next compute to overlap),
S_DIVIDE (35 cycles/row x 4 rows, then either the next row group or S_IDLE
with the one-cycle done pulse). busy = (state != S_IDLE); done is a
registered pulse true only on the cycle the FSM lands back in S_IDLE, so
busy and done are never both 1.

Cycle formula derivation: per row group, (nblk + 1) blocks of 16 cycles
(nblk computes, one trailing drain) plus 4 * 35 divide cycles =
16*nblk + 16 + 140 = 16*nblk + 156; nblk groups plus the accepted start
edge:

```
total = nblk * (16*nblk + 156) + 1,   nblk = n_len / 4
```

At n_len = 64 (nblk = 16): 16 * (256 + 156) + 1 = 16 * 412 + 1 = 6593. The
cocotb testbench reads cycle_count on every run and checks it against this
closed form; the recorded values (tb/attention_top/cycles.txt) are 173, 377,
881, 2273, 6593 for N = 4, 8, 16, 32, 64, every one matching the formula
exactly. The formal-coverage auditor re-verified the formula independently
[EVIDENCE: audit-attention_top-formal-coverage].

### 7.7 Verification evidence

`make verify MODULE=attention_top` exits 0 [EVIDENCE: verify-attention_top],
re-verified after the BRAM conversion
[EVIDENCE: bram-conversion-attention_top].

Simulation (tb/attention_top/test_attention_top.py): 6 tests, all passing on
two seeds, bit-exact end to end against model/attn.py attn_fixed
[EVIDENCE: audit-attention_top-formal-coverage]:

1. end_to_end_golden: full random N=64 inference, every output byte compared
   against the golden model, cycle_count checked against the closed form.
2. corners: directed extreme matrices (constant blocks, sign mixes, values
   forcing rescales and the LUT zero tail) at multiple n_len values.
3. multi_run_no_reset: consecutive runs without reset between them prove no
   stale state leaks across runs (the load-before-use and row_start_d
   rebasing contracts).
4. rst_mid_run: reset asserted mid-inference returns the FSM to S_IDLE and a
   subsequent clean run computes correctly.
5. random_regression: randomized n_len and matrices across repeated runs,
   all bit-exact.
6. write_port_readback: the load port and the registered read port honor
   their address/latency contracts.

Line coverage: the check_coverage.py gate passed inside make verify, and the
formal-coverage auditor confirmed every missed point is
unreachable-defensive code [EVIDENCE: audit-attention_top-formal-coverage].
Raw counters: tb/attention_top/coverage.dat. The exp_lut.svh ROM lines are
excluded from this module's instrumentation by tb/attention_top/coverage.vlt
because the ROM is already exhaustively swept and equivalence-proven
standalone in tb/online_softmax (the .vlt file documents the rationale).

Formal (formal/attention_top.sby: BMC depth 10, smtbmc yices,
reset-assumed): PASS with 7 assertions and 1 assumption, audited non-vacuous
[EVIDENCE: audit-attention_top-formal-coverage]; runtime 2.8 s after the
BRAM conversion (down from about 60 s)
[EVIDENCE: bram-conversion-attention_top]. Scope is control-only per the
project's formal-is-a-subset rule: reset state (S_IDLE, busy=0, done=0,
cycle_count=0), busy/done mutual exclusion, done implies idle, cycle_count
monotone non-decreasing while busy. None of the properties reference the
RAMs, the NUM accumulators, the score/rescale arithmetic, or the divider
bank; the FSM's transition conditions depend only on counters and start, so
the property set stays solver-cheap even though the transition relation
still elaborates the whole datapath. Two deliberate, documented mechanics:

- `initial assume (rst)`: BMC's free initial state can otherwise place the
  FSM in a garbage configuration no real reset produces (done=1 with
  state != S_IDLE), falsifying a STATE INVARIANT like "done implies idle"
  at step 0. Scoping the trace space to reset-reachable traces is the
  honest bounded claim for state invariants; the pure TRANSITION properties
  in mac_unit and online_softmax do not need it because they hold from any
  starting state. The full reasoning is a comment block in the RTL FORMAL
  section (rtl/attention_top.sv).
- Submodule assertion strip (pasted from formal/attention_top.sby):

```
[script]
read_verilog -sv -formal -DFORMAL mac_unit.sv matmul_tile.sv online_softmax.sv attention_top.sv
prep -top attention_top
chformal -assert -remove mac_unit
chformal -assert -remove matmul_tile
chformal -assert -remove online_softmax
```

  Each stripped contract is already proven standalone and countersigned in
  its own .sby run over the identical, unmodified module; re-proving them
  inside an integration BMC that also elaborates 3 RAMs, a ROM, 32
  multipliers, and a 16-wide divider bank is redundant solver load. The
  solver is yices rather than z3 because z3 hangs (>10 minutes, independent
  of depth) on this memory-heavy model while yices completes depth 10 in
  about a minute pre-conversion; the trials are documented in the .sby
  header.

The formal-coverage auditor judged the whole reduction chain sound and
re-ran everything independently
[EVIDENCE: audit-attention_top-formal-coverage]; the lint-synth auditor
verified the prefetch logic against the FSM, the divider against
docs/uarch.md 3.8, lint clean, yosys check 0 problems, no $_DLATCH_
[EVIDENCE: audit-attention_top-lint-synth].

### 7.8 Benchmark vs the CPU golden model (Phase 2 deliverable)

Full writeup: docs/benchmark.md. Two measured quantities and one derived
view:

- Accelerator cycles (clock-independent simulation facts, recorded by the
  cocotb test into tb/attention_top/cycles.txt): 173 / 377 / 881 / 2273 /
  6593 cycles for N = 4 / 8 / 16 / 32 / 64, each matching the section 7.6
  closed form exactly.
- CPU baseline (build/cpu_baseline.txt, scripts/benchmark_cpu.py): the
  bit-exact C++ golden model, -O2, single thread, median of 15 full-process
  runs, minus the measured 1.154 ms process floor. Compute-only estimates:
  82 us (N=16), 140 us (N=32), 275 us (N=64); at N = 4 and 8 the
  subtraction is inside measurement noise and no number is claimed.
- Utilization view (derived, clock-free): one N=64 inference performs
  2 * 64^2 * 16 = 131072 MACs on the Q.K^T side plus the same on the PV
  side, about 262144 MACs in 6593 cycles = 39.8 sustained MAC/cycle against
  32 instantiated multipliers (16 tile + 16 PV), i.e. the multiply datapath
  is over 100% occupied while compute and drain overlap, with the gap to
  the ideal coming from the 156-cycle per-group tail (S_DRAIN_LAST +
  S_DIVIDE).

Honest caveats, in order of importance: (1) the CPU baseline is the
reference model written for bit-exactness (int64 arithmetic, asserts on),
not a tuned int8 kernel; the table demonstrates cycle economy, not victory
over optimized CPU software. (2) Converting cycles to wall time needs a
clock, and NO attention_top netlist has been through STA; only cycle counts
and CPU milliseconds are measurements. docs/benchmark.md's illustrative
times use a 44 MHz figure from a pre-closure Phase 4 infrastructure smoke
run; the signed-off Phase 4 tool estimates for the standalone online_softmax
core (the design's timing limiter) are 38.5 MHz naive and 76.9 MHz pipelined
(section 9.4), and neither number has been established for the integrated
top. (3) Accelerator cycles grow with N^2 like the CPU's; the constant
factor and the deterministic latency are the story.

### 7.9 Known gaps

- No STA has been run on the attention_top netlist itself; the Phase 4
  timing work characterized online_softmax (the predicted and confirmed
  critical-path owner among the synthesized modules) plus mac_unit and
  matmul_tile smoke runs. An integrated-top STA is future work.
- Formal is control-only (documented scope); all datapath assurance is the
  bit-exact end-to-end simulation against attn_fixed.
- The divide phase is not overlapped with the next group's compute
  (documented future optimization, docs/uarch.md 8.3).
- docs/verification_plan.md sections about attention_top were written
  before its verify landed and remain in plan voice there; this guide and
  EVIDENCE.md carry the result claims.

## 8. Phase 3 closure: functional coverage and the exact-max property

Phase 3 layered a real functional coverage model and a strengthened formal
property onto online_softmax. `[EVIDENCE: phase3-closure]` records the
closure: 52/52 reachable bins hit, the directed DEN worst case exact, and
the exact-max property proven (18 assertions, sby PASS in about 5 s).

### 8.1 The functional coverage model

tb/online_softmax/test_softmax_coverage.py defines 53 bins in 9 groups and a
tracker sampled on every accepted element; the report is written to
tb/online_softmax/func_coverage.txt. Group totals, read from that report:

| Group | Bins | What it pins down |
|-------|------|-------------------|
| score | 7 | s value ranges incl. both exact extremes and exact zero |
| diff_w | 6 + 1 unreachable | the w-side difference: zero, small negative, domain interior, exact clamp edge -16384, below clamp, zero tail |
| idx_w | 8 | w LUT index bands incl. exact 0, 1, 1023 |
| idx_r | 8 | r LUT index bands (rescale side) |
| rescale | 3 | identity r = 0x8000, genuine rescale, r in the zero tail |
| l_value | 6 | denominator magnitude bands up to l = 2^23 |
| row_length | 6 | row lengths incl. 1, 2, and 256 |
| control | 5 | idle gaps, back-to-back rows |
| cross | 3 | max-update x zero-tail w; identity r x l > 2^21; clamp edge x row length 256 |

TOTAL: 52/52 reachable bins hit (100.0%), 1 documented-unreachable, 53
defined (tb/online_softmax/func_coverage.txt). The one unreachable bin is
declared, not waved off: diff_w.positive_impossible can never be attempted
because m_new = max(m_base, s) makes s <= m_new by construction; the same
fact is asserted structurally in the tracker and directly in the RTL FORMAL
block (assert (diff_s <= 17'sd0)). The report prints the reason string and
an empty "unhit reachable bins" list.

Stimulus is two tests: constrained_random_coverage (weighted-random rows
biased toward clamp edges, extremes, and long rows, checked cycle-by-cycle
against the model mirror like every other test) and directed_den_worst_case,
which drives a 256-element all-maximum row so every element contributes
w = 2^15 under identity rescale and the denominator lands on exactly
l = 256 * 2^15 = 2^23, the top of the docs/uarch.md 3.6 induction bound,
checked for exact equality, closing an earlier audit finding that no test
had ever reached the bound.

### 8.2 The exact-max formal property

The original property list asserted m monotone non-decreasing within a row.
The formal-coverage auditor flagged the weakness: a bug that latched a WRONG
value larger than $past(m) would still look monotonic. Phase 3 added a
property that pins m to the exact recurrence, solver-cheap because it only
compares already-registered values (no ROM, no multiplier). Pasted verbatim
from rtl/online_softmax.sv (g_f_lat1; the same pair also lives in g_f_lat2):

```systemverilog
            // m monotone non-decreasing between row starts. Kept alongside
            // the stronger property below (harmless, avoids churn in the
            // audited property list); the exact-max recurrence strictly
            // subsumes it.
            assert (m >= $past(m));
            // Formal-coverage auditor finding: the monotonicity assert above
            // passes even if m latched a wrong value larger than $past(m) (a
            // bug that overshoots the true max would still look monotonic).
            // This property pins m to the exact section-6 recurrence
            // m_new = max(m, s), evaluated only over $past(s)/$past(m) (a
            // comparison and a mux over already-registered values, no ROM or
            // multiplier reasoning), so it strictly subsumes monotonicity.
            assert (m == (($past(s) >= $past(m)) ? $past(s) : $past(m)));
```

With this addition the default-configuration task carries 18 assertions,
sby PASS [EVIDENCE: phase3-closure], re-proven non-vacuous to depth 20 in
the Phase 4 re-audit [EVIDENCE: audit-online_softmax-pipe-formal-coverage].

## 9. Phase 4: the PIPE_ROM pipelining iteration, sky130 STA, and GLS

Phase 4's brief was one pipelining iteration with before/after synthesis and
timing numbers. Everything in this section is a sandbox tool result at the
sky130_fd_sc_hd tt_025C_1v80 corner (yosys mapping, OpenSTA 2.0.17, ideal
clock, zero-margin I/O); nothing is a hardware measurement
[EVIDENCE: phase4-sta].

### 9.1 The registered-ROM variant, spec first

The variant was SPECIFIED before it was coded: docs/uarch.md 8.2.1 is the
normative definition (stage boundary, latency, alignment, back-to-back row
semantics, formal task split), written in the same spec-first discipline as
the rest of the design. The parameter contract:

- PIPE_ROM = 0 (default): elaborates exactly the single-cycle logic of
  section 6; out_valid latency 1; the configuration attention_top
  instantiates. The lint-synth auditor confirmed the g_lat1 branch
  byte-identical to the previously audited arithmetic
  [EVIDENCE: audit-online_softmax-pipe-lint-synth].
- PIPE_ROM = 1: the critical path diff -> clamp -> index -> ROM ->
  (l * r multiply) -> rshr -> add is cut at the ROM output. Stage 1 (the
  cycle that consumes s): base mux, max, both diffs, both clamps, both LUT
  lookups; the ROM outputs register into pipe registers w_p and r_p
  together with a pipelined valid v_p and pipelined row context rs_p.
  Stage 2 (the next cycle): the l_base mux (rs_p selects 0), the 24u x 16u
  multiply, rshr, add; on its commit edge l updates and (w_p, r_p, v_p)
  move to the visible (w, r, out_valid). out_valid latency becomes 2.
  Throughput is unchanged: one element per cycle, no backpressure, rows
  back to back with no dead cycle, and the pipe drains by itself.

Two non-obvious design points, both from docs/uarch.md 8.2.1:
- m stays at latency 1 BY NECESSITY: element k+1's stage-1 diffs must read
  the m already updated by element k (the m recurrence must close in one
  cycle to sustain throughput), and its compare-and-mux path is short.
  Consequence: in PIPE_ROM = 1 the visible m LEADS out_valid by one cycle.
- No l forwarding network exists because the l register IS the stage-2
  accumulator: the loop l -> multiply -> rshr -> add -> l closes
  combinationally inside stage 2, elements enter stage 2 at most one per
  cycle, and rs_p carries a new row's boundary down the pipe so a
  back-to-back row rebases at l = 0 even when the previous row's last
  commit lands on the same edge.

The per-element VALUES of m, l, w, r are identical in both configurations;
only alignment shifts. The whole g_lat2 branch, pasted verbatim from
rtl/online_softmax.sv:

```systemverilog
  end else begin : g_lat2
    // PIPE_ROM = 1 (uarch.md 8.2.1): stage boundary at the ROM output.
    // Stage 1 registers the lookups (w_p, r_p) plus pipelined valid (v_p)
    // and row context (rs_p); m commits in stage 1 (latency 1, required so
    // the next element's diffs see it). Stage 2 runs the l update a cycle
    // later. No l forwarding is needed: the l register IS the stage-2
    // accumulator, its multiply/rshr/add loop closes within stage 2 in one
    // cycle, and rs_p (not the live row_start) selects the l = 0 base so a
    // back-to-back new row cannot corrupt the update in flight.
    logic        v_p;  // stage-1/2 pipe: element in flight
    logic        rs_p;  // pipelined row_start of that element
    logic [15:0] w_p;  // pipelined ROM outputs
    logic [15:0] r_p;
    logic [23:0] l_base;
    logic [39:0] lr_prod;  // l * r, 24u x 16u, never registered
    logic [40:0] lr_rnd;  // + 2^14 round-half-up bias
    logic [23:0] l_resc;  // rshr(l * r, 15)
    logic [23:0] l_n;

    always_comb begin
      l_base  = rs_p ? 24'd0 : l;
      // Rounding site 3, same arithmetic and same non-truncation argument
      // as g_lat1; only the operand registers differ.
      lr_prod = l_base * r_p;
      lr_rnd  = {1'b0, lr_prod} + 41'd16384;
      l_resc  = 24'(lr_rnd >> 15);
      l_n     = l_resc + 24'(w_p);
    end

    always_ff @(posedge clk) begin
      if (rst) begin
        m         <= MInit;
        l         <= 24'd0;
        w         <= 16'd0;
        r         <= 16'd0;
        out_valid <= 1'b0;
        v_p       <= 1'b0;
        rs_p      <= 1'b0;
        w_p       <= 16'd0;
        r_p       <= 16'd0;
      end else begin
        // Stage 1 commit: m plus the pipe registers.
        v_p <= in_valid;
        if (in_valid) begin
          m    <= m_n;
          w_p  <= w_n;
          r_p  <= r_n;
          rs_p <= row_start;
        end
        // Stage 2 commit: the l update and the visible w, r, out_valid.
        out_valid <= v_p;
        if (v_p) begin
          l <= l_n;
          w <= w_p;
          r <= r_p;
        end
      end
    end
  end
```

Added state derivation: w_p (16) + r_p (16) + v_p (1) + rs_p (1) = 34 extra
flip-flops, 73 + 34 = 107, and the auditor's netlist count is exactly 107
[EVIDENCE: audit-online_softmax-pipe-lint-synth].

### 9.2 The parameter-config testbench

tb/online_softmax/Makefile grew a PIPE_ROM knob: PIPE_ROM=1 elaborates the
variant via a verilator elaboration-time override (-GPIPE_ROM=1), runs a
separate latency-2-aware test module (test_softmax_pipe_rom.py), and is
fully artifact-isolated (its own sim_build_pipe_rom1/, results_pipe_rom1.xml
and coverage_pipe_rom1.dat) so a variant run can never clobber the default
run's gate artifacts. The 8 tests, all passing on two seeds and value-exact
against the golden mirror [EVIDENCE: audit-online_softmax-pipe-formal-coverage]:

1. single_row_exact_values: one row, every visible port checked cycle by
   cycle against the latency-2 mirror.
2. back_to_back_rows_across_stage_boundary: a new row's first element
   entering stage 1 while the old row's last element commits in stage 2.
3. gap_patterns: in_valid bubbles in every alignment, including one
   immediately after row_start.
4. drain_behavior: out_valid falls exactly 2 cycles after the last
   in_valid; the pipe self-drains.
5. m_leads_out_valid_by_one: the documented visible-m lead on max updates.
6. reset_mid_pipe: rst with elements in flight clears both stages.
7. den_worst_case_pipe_rom1: the 256-element all-max row reaching exactly
   l = 2^23 in the pipelined configuration.
8. constrained_random_soak: long weighted-random soak against the mirror.

A dedicated 6-bin pipe coverage model
(tb/online_softmax/func_coverage_pipe_rom1.txt) pins the latency-2 corners:
back_to_back_across_stage_boundary, bubble_immediately_after_row_start_lat2,
reset_mid_pipe_elements_in_flight,
drain_falls_exactly_2_cycles_after_last_in_valid,
m_leads_out_valid_by_one_on_max_update, den_worst_case_lat2_l_eq_2p23; the
report shows 6/6 hit. Beyond re-running everything on two seeds, the
formal-coverage auditor wrote an independent 300-stream scratch check
proving the two elaborations produce value-identical (m, l, w, r) sequences,
and noted the one corner simulation left open (row_start asserted without
in_valid) is closed by the formal alignment properties
[EVIDENCE: audit-online_softmax-pipe-formal-coverage].

### 9.3 Formal, both elaborations

formal/online_softmax.sby runs two tasks, pasted:

```
[tasks]
p0
p1

[options]
mode bmc
depth 20

[engines]
smtbmc z3

[script]
p0: read_verilog -sv -formal -DFORMAL online_softmax.sv
p1: read_verilog -sv -formal -DFORMAL -defer online_softmax.sv
p1: chparam -set PIPE_ROM 1 online_softmax
prep -top online_softmax
```

p0 (18 assertions) is the audited default property list of sections 6.4 and
8.2. p1 (17 assertions) proves for the PIPE_ROM = 1 elaboration: the
config-independent clamp facts, the unchanged latency-1 exact-max m
recurrence, and the latency-2 alignment expressed purely over ports with two
reset-free history cycles (out_valid equals in_valid two cycles earlier;
l, w, r hold and out_valid is low when no element was accepted two cycles
earlier), so no assertion reaches into the g_lat2 pipe registers or assumes
anything about their pre-reset values. Both PASS at depth 20; the auditor
verified in the generated SMT that the p1 model really elaborates g_lat2
(the chparam took effect) and that both tasks are non-vacuous
[EVIDENCE: audit-online_softmax-pipe-formal-coverage]. As with p0, value
checking of l, w, r against the golden model is cocotb's job.

### 9.4 Synthesis and STA: the before/after table

Flow: yosys synth + dfflibmap + abc to sky130_fd_sc_hd
(build/synth_netlist_online_softmax.log and
build/synth_netlist_online_softmax_pipe1.log; the variant is elaborated with
`read_verilog -defer` + `chparam -set PIPE_ROM 1`), then OpenSTA
(scripts/sta.tcl) at the 10 ns target and at each config's met period. All
numbers below are read from the named logs; Fmax is derived as 1/period.

| Metric (sky130 tt, tool estimates) | PIPE_ROM=0 naive | PIPE_ROM=1 pipelined |
|------------------------------------|------------------|----------------------|
| setup slack at 10 ns | -15.574 ns (VIOLATED, build/sta_online_softmax.log) | -2.664 ns (VIOLATED, build/sta_online_softmax_pipe1.log) |
| met period | 26 ns, slack +0.426 (build/sta_online_softmax_met26ns.log) | 13 ns, slack +0.336 (build/sta_online_softmax_pipe1_met13ns.log) |
| Fmax (tool estimate) | 1/26 ns = 38.5 MHz | 1/13 ns = 76.9 MHz |
| worst path | m register through diff, clamp, ROM, multiply, rshr, add into the l register | m register through diff, clamp, ROM into the w_p pipe register |
| cells | 3842 (build/synth_netlist_online_softmax.log) | 3817 (build/synth_netlist_online_softmax_pipe1.log) |
| flip-flops | 73 | 107 |
| area | 24587.3 um2 | 26880.8 um2 |
| out_valid latency | 1 | 2 |
| throughput | 1 element/cycle | 1 element/cycle |

Derived deltas: 26/13 = 2.0x Fmax; 26880.8 / 24587.3 = 1.093, +9.3% area.
One pipelining iteration bought 2.0x tool-estimated Fmax for +9% area. The
lint-synth auditor confirmed in the STA path report that the stage cut is
real and lands where the spec says: the PIPE_ROM=1 worst path ends at the
w_p pipe register and the multiply is off it
[EVIDENCE: audit-online_softmax-pipe-lint-synth].

Stated plainly, because it is the most important honesty point of Phase 4:
NEITHER configuration meets the 10 ns target period. mac_unit and
matmul_tile meet 10 ns (+4.101 ns slack each, build/sta_mac_unit.log,
build/sta_matmul_tile.log); the softmax recurrence is the design's Fmax
limiter even after pipelining, and closing 10 ns would need a second cut
through the multiply/rshr/add stage, out of scope for Phase 4's
one-iteration brief. Both auditors' reports and the evidence row flag this
explicitly [EVIDENCE: phase4-sta],
[EVIDENCE: audit-online_softmax-pipe-lint-synth].

QoR control: the pre-parameterization RTL (the audited baseline, preserved
as build/online_softmax_head_baseline.sv) was re-synthesized through the
identical flow and reports slack -17.057 ns at 10 ns
(build/sta_online_softmax_head_baseline.log), versus -15.574 for the
parameterized default. The parameterization did not degrade QoR
[EVIDENCE: phase4-sta].

### 9.5 Gate-level simulation of both netlists

The Phase 4 exit gate included GLS: both sky130 netlists replay a
546-checked-cycle golden vector set under iverilog with the
sky130_fd_sc_hd FUNCTIONAL cell models, 0 errors each
(build/gls_lat1.log and build/gls_lat2.log, both ending
"GLS PASS: 546 cycles checked, 0 errors") [EVIDENCE: phase4-sta].

What makes this GLS trustworthy:

- The expected vectors are SPEC-DERIVED, not RTL-derived:
  scripts/gen_gls_vectors.py computes them from the normative text of
  docs/uarch.md 8.2/8.2.1 using model/attn.py's primitives (lut_index,
  rshr, gen_exp_lut), so a pass means netlist ports match the spec-derived
  golden sequence cycle by cycle, with no possibility of an RTL bug
  propagating into the expectations.
- One shared 549-line stimulus file (build/gls_stim.hex: a 3-cycle initial
  reset, then 546 checked cycles) drives BOTH configs; per-config expected
  files (build/gls_expected_lat1.hex, build/gls_expected_lat2.hex) encode
  the latency-1 and latency-2 alignments. Identical stimulus is also what
  makes the Phase 5 activity comparison honest.
- Stimulus content (from the generator's docstring): back-to-back rows
  including length-1 and length-2 rows straddling the pipe depth, in_valid
  bubbles including one immediately after row_start, the 256-element
  all-max DEN worst case reaching l = 2^23, and a constrained-random tail;
  deterministic seed, rows never exceed 256 elements.
- Cell models: the PDK-distributed sky130_fd_sc_hd.v + primitives.v, with
  two mechanical iverilog compatibility fixes applied to a LOCAL COPY in
  build/gls_cells (bare token after `endif rewritten as a comment;
  UNIT_DELAY defined empty for the zero-delay functional intent); the
  source models are untouched (tb/gls/Makefile documents both).

Run it: `make -C tb/gls all` (targets lat1 and lat2; each greps its log for
"GLS PASS"). The runs dump build/gls_lat1.vcd and build/gls_lat2.vcd, which
Phase 5 consumes.

### 9.6 Toolchain integrity note: the Makefile .PHONY fix

Found during Phase 4 and worth recording: the repo has a formal/ DIRECTORY,
and the Makefile's `formal` target was not declared phony, so `make formal`
resolved against the directory, reported "up to date", and silently skipped
sby inside `make verify`. The fix, pasted from the Makefile:

```
# Every target here is a command, not a file. Without this, the formal/
# directory shadows the formal target (make says "up to date" and silently
# skips sby inside make verify). Found 2026-07-16 during Phase 4.
.PHONY: lint sim coverage synth-check formal verify verify-fw synth-netlist sta model-check audit-guide
```

Impact assessment, stated honestly: no unproven formal claim ever shipped,
because every formal PASS in EVIDENCE.md was independently established by
auditors invoking sby directly (each audit row's command column lists the
sby re-run), and the standalone sby runs of Phases 3 and 4 are their own
evidence [EVIDENCE: phase3-closure], [EVIDENCE: phase4-sta]. What the fix
changes is the gate itself: from this commit on, `make verify` genuinely
executes the formal leg instead of skipping it.

## 10. Phase 5: switching-activity power proxy and the tradeoff writeup

Full writeup: docs/tradeoffs.md; evidence row [EVIDENCE: phase5-docs]. All
numbers are sandbox tool estimates at the sky130 tt corner; none are
hardware measurements.

### 10.1 Method

The two GLS VCDs of section 9.5 (identical 549-cycle stimulus by
construction) feed two steps:

1. scripts/toggle_count.py counts 0-to-1/1-to-0 transitions on every dumped
   net per netlist (x/z edges ignored; vector signals count one toggle per
   changed bit). A toggle count weights every net equally (no capacitance,
   no slew, no clock tree under an ideal clock): honest for RELATIVE
   comparison of two netlists on the same stimulus through the same
   library, which is exactly the Phase 5 question.
2. scripts/power_proxy.tcl runs OpenSTA report_power with the measured
   AVERAGE activity applied globally via set_power_activity (this OpenSTA
   build predates read_power_activities, so per-net VCD annotation is not
   possible). This makes the wattage a tool estimate CALIBRATED by measured
   average activity, not a per-net activity simulation, and it is labeled
   that way everywhere it is quoted.

### 10.2 Results

Switching activity, identical stimulus (from scripts/toggle_count.py over
build/gls_lat1.vcd and build/gls_lat2.vcd; derivations shown):

| Metric | PIPE_ROM=0 | PIPE_ROM=1 | Delta |
|--------|------------|------------|-------|
| dumped nets | 25317 | 25953 | 25953/25317 = +2.5% |
| total toggles | 388779 | 393472 | 393472/388779 = +1.2% |
| toggles/net/cycle | 388779/(25317*546) = 0.0281 | 393472/(25953*546) = 0.0278 | -1.3% |

Calibrated power proxy (OpenSTA report_power totals read from the named
logs; duty 0.5):

| Operating point | PIPE_ROM=0 | PIPE_ROM=1 | Delta |
|-----------------|------------|------------|-------|
| at own met period | 3.65e-4 W = 0.365 mW at 38.5 MHz (build/power_proxy_lat1_26ns.log) | 9.54e-4 W = 0.954 mW at 76.9 MHz (build/power_proxy_lat2_13ns.log) | 2.6x |
| iso-frequency, both at 38.5 MHz | 0.365 mW | 4.77e-4 W = 0.477 mW (build/power_proxy_lat2_26ns.log) | 0.477/0.365 = +31% |
| energy per element (period x power at 1 element/cycle) | 26 ns * 0.365 mW = 9.5 pJ | 13 ns * 0.954 mW = 12.4 pJ | +31% |

Reading the numbers: the activity cost of pipelining is negligible (+1.2%
toggles on identical work), but the proxy power cost is not: +31% at
iso-frequency, dominated by the internal (clock-pin) power of the 34 extra
flops in an estimate where sequential internal power is 87 to 90 percent of
the total (Internal vs Total columns of the named logs). The pipelined
config is a latency/frequency win, not an energy win: choose PIPE_ROM=1
when the system clock demands it, keep PIPE_ROM=0 when 38 MHz suffices and
energy or latency-1 alignment matters. attention_top instantiates the
default and is unchanged.

### 10.3 Documented proxy biases (docs/tradeoffs.md section 4)

- Zero-delay GLS hides glitches: the naive config's long multiply cone sees
  unregistered ROM outputs and will glitch more in real timing than this
  proxy shows, so the proxy likely UNDERSTATES the naive config's dynamic
  power; the registered-ROM variant feeds its multiplier from flops, which
  suppresses that glitch class. The real iso-frequency gap is therefore
  plausibly smaller than +31% and the sign cannot be resolved without
  SDF-annotated GLS or silicon.
- Global-average activity flattens per-net variation; the ideal clock means
  no clock-tree power on either side (a real tree would scale with the +47%
  flop count).
- tt corner only; no wire parasitics (nothing is placed or routed at this
  phase).

These limits are inherent to Phase 5; the Phase 7 OpenLane flow upgrades the
comparison with routed parasitics and, with a newer OpenSTA, per-net VCD
annotation (docs/phase7_physical_guide.md section 7).

## 11. Status and roadmap

### 11.1 The sandbox/silicon wall, restated

Everything claimed above is sandbox-provable: simulation, coverage, lint,
synthesis to a netlist, bounded formal, STA, GLS, and a calibrated power
proxy. The interim voice for the whole design: verified in simulation and
formal; synthesized to latch-free netlists; the online_softmax core meets
timing at 38.5 MHz (naive) and 76.9 MHz (pipelined) in OpenSTA at the
sky130 tt corner, and does not meet the 10 ns target in either
configuration; not implemented on FPGA, not taped out. There is no measured
Fmax, no bench power number, and no hardware bring-up result anywhere in
this project, and none is claimed.

| Item | Status |
|------|--------|
| Phases -1 to 5 | closed per PLAN.md/EVIDENCE.md ([Ready]; [Done] additionally requires the owner's Mode-B replication pass, not yet run) |
| Phase 6: FPGA bring-up (Basys 3, docs/phase6_fpga_guide.md) | PENDING-HARDWARE (needs a real board and user bench evidence) |
| Phase 7: OpenLane RTL-to-GDS + routed-parasitic power | future work (sandbox-achievable, not started; docs/phase7_physical_guide.md) |
| Phase 7: TinyTapeout silicon | PENDING-HARDWARE (not taped out; needs user evidence) |

### 11.2 Stage-gated resume bullets

Only the following bullets are currently claimable, each clause mapped to
its evidence. The bracketed clauses are the load-bearing ones.

Bullet 1: "Built a bit-exact dual golden model (Python and C++) for a
fixed-point streaming attention engine [and proved them byte-identical
across 14 random and corner cases including N = 256, with a
derivation-backed error budget met at 0.77 LSB worst case against float]."

| Clause | Evidence |
|--------|----------|
| dual golden model, byte-identical, 14 cases | [EVIDENCE: model-crosscheck], model/crosscheck.py |
| error budget met, 0.77 LSB worst case | [EVIDENCE: model-crosscheck], docs/uarch.md section 7 |

Bullet 2: "Designed and verified the attention core datapath in
SystemVerilog (MAC, 4x4 output-stationary matmul tile, online softmax)
[each passing cocotb simulation against the golden model on multiple seeds,
functional and line coverage gates, latch-free yosys synthesis, and
SymbiYosys bounded proofs, all independently re-run and countersigned by
two auditors]."

| Clause | Evidence |
|--------|----------|
| mac_unit verified, 4/4 tests, 100% coverage, latch-free, BMC PASS | [EVIDENCE: verify-mac_unit], [EVIDENCE: audit-mac_unit-lint-synth], [EVIDENCE: audit-mac_unit-formal-coverage] |
| matmul_tile verified, 6/6 tests two seeds, 100% coverage, 384 FF latch-free, depth-5 BMC non-vacuous | [EVIDENCE: verify-matmul_tile], [EVIDENCE: audit-matmul_tile-lint-synth], [EVIDENCE: audit-matmul_tile-formal-coverage] |
| online_softmax verified, 9/9 tests two seeds, 52/52 functional bins, latch-free both configs, depth-20 BMC non-vacuous both configs | [EVIDENCE: verify-online_softmax], [EVIDENCE: phase3-closure], [EVIDENCE: audit-online_softmax-pipe-lint-synth], [EVIDENCE: audit-online_softmax-pipe-formal-coverage] |

Bullet 3: "Integrated the full engine (tiled matmul + online softmax + NUM
accumulation + restoring divider bank) behind BRAM-inferable single-port
memories [bit-exact end to end against the golden model on two seeds,
control-only bounded formal, dual auditor countersign; the memory rewrite
cut formal runtime from about 60 s to 2.8 s and synthesis from 5m23s/4.77GB
to 1m15s/1.25GB while staying bit-identical; 6593 cycles for N = 64,
matching the closed-form cycle model exactly]."

| Clause | Evidence |
|--------|----------|
| end-to-end bit-exact, verify green, countersigned | [EVIDENCE: verify-attention_top], [EVIDENCE: audit-attention_top-lint-synth], [EVIDENCE: audit-attention_top-formal-coverage] |
| BRAM conversion numbers, bit-identical | [EVIDENCE: bram-conversion-attention_top] |
| cycle counts vs closed form | tb/attention_top/cycles.txt, [EVIDENCE: audit-attention_top-formal-coverage] |

Bullet 4 (interim voice, sandbox timing only): "Closed a spec-first
pipelining iteration on the softmax critical path [registered-ROM variant,
default bit-identical, doubling tool-estimated Fmax from 38.5 to 76.9 MHz
at the sky130 tt corner in OpenSTA for +9% area; both netlists pass
gate-level simulation against spec-derived vectors with 0 errors; the 10 ns
target is not met in either configuration and is documented as the design's
open timing limiter; not implemented on FPGA, not taped out]."

| Clause | Evidence |
|--------|----------|
| variant, STA numbers, 10 ns not met, GLS 0 errors | [EVIDENCE: phase4-sta], build/sta_online_softmax*.log, build/gls_lat*.log |
| dual re-audit of the parameterization | [EVIDENCE: audit-online_softmax-pipe-lint-synth], [EVIDENCE: audit-online_softmax-pipe-formal-coverage] |

Bullet 5 (interim voice, proxy estimates only): "Quantified the pipelining
tradeoff with an identical-stimulus gate-level switching-activity proxy
[+1.2% toggles, +31% iso-frequency power and 9.5 vs 12.4 pJ/element in a
calibrated OpenSTA estimate at the tt corner, with the proxy's biases
(zero-delay glitch blindness, global-average activity, ideal clock)
documented alongside the numbers]."

| Clause | Evidence |
|--------|----------|
| toggle counts, calibrated power, energy/element, biases | [EVIDENCE: phase5-docs], docs/tradeoffs.md, build/power_proxy_*.log |

No FPGA, hardware-timing, bench-power, or silicon bullet exists because no
evidence row exists for any of them.

## 12. Reproduce it yourself

All commands run from the repo root (/home/owner/p1-attention) unless noted.
The verify targets append their own EVIDENCE.md rows on success.

```
# Phase -1: prove the toolchain before trusting any RTL result
make verify MODULE=tool_smoke COVERAGE_STUB=1

# Phase 0: golden models bit-identical + float gate (14 cases)
make model-check

# Per-module full gates (each runs lint, sim, coverage, synth-check, formal)
make verify MODULE=mac_unit
make verify MODULE=matmul_tile
make verify MODULE=online_softmax
make verify MODULE=attention_top

# Individual stages, if you want to see one gate at a time
make lint        MODULE=online_softmax
make sim         MODULE=online_softmax SEED=1
make sim         MODULE=online_softmax SEED=7   # different stimulus, same pass
make coverage
make synth-check MODULE=online_softmax          # writes build/synth.log
make formal      MODULE=online_softmax          # runs BOTH sby tasks (p0, p1)
sby -f formal/attention_top.sby                 # integration BMC, yices, ~3 s

# PIPE_ROM = 1 simulation (artifact-isolated, latency-2 test module)
make -C tb/online_softmax PIPE_ROM=1 SEED=1 MODULE=

# Phase 4: sky130 netlists + OpenSTA (LIB defaults to the tt liberty file)
make synth-netlist MODULE=online_softmax
make sta           MODULE=online_softmax PERIOD_NS=26   # met: slack +0.426
yosys -p 'read_verilog -sv -defer rtl/online_softmax.sv; \
  chparam -set PIPE_ROM 1 online_softmax; hierarchy -top online_softmax; \
  synth -top online_softmax; dfflibmap -liberty $LIB; abc -liberty $LIB; \
  opt_clean; stat -liberty $LIB; \
  write_verilog -noattr build/online_softmax_pipe1_netlist.v'
LIB=$LIB NETLIST=build/online_softmax_pipe1_netlist.v MODULE=online_softmax \
  PERIOD_NS=13 opensta -no_init scripts/sta.tcl    # met: slack +0.336

# Phase 4: gate-level simulation of both netlists (spec-derived vectors)
make -C tb/gls all      # expect "GLS PASS: 546 cycles checked, 0 errors" x2

# Phase 5: toggle counts + calibrated power proxy
python3 scripts/toggle_count.py build/gls_lat1.vcd build/gls_lat2.vcd
LIB=$LIB NETLIST=build/online_softmax_netlist.v MODULE=online_softmax \
  PERIOD_NS=26 ACTIVITY=0.0281 opensta -no_init scripts/power_proxy.tcl

# Regenerate the LUT artifacts from the single source (should be no-ops)
python3 model/attn.py --emit-lut model/exp_lut.hex
python3 model/attn.py --emit-lut-svh rtl/exp_lut.svh

# Audit this document for unbacked hardware claims
make audit-guide
```

Key artifacts to inspect: EVIDENCE.md (the claim ledger), docs/uarch.md
(the normative numeric contract, incl. 8.2.1 and 8.3), docs/benchmark.md
and docs/tradeoffs.md (the Phase 2 and Phase 5 writeups),
docs/verification_plan.md (the Phase 5 plan document), build/synth*.log and
build/sta_*.log (yosys and OpenSTA reports), build/gls_lat*.log and
build/power_proxy_*.log (GLS and power proxy), tb/<module>/coverage.dat and
tb/online_softmax/func_coverage*.txt (coverage counters and functional
bins), formal/<module>*/logfile.txt (sby proof logs), and
tb/<module>/results*.xml (cocotb results).
