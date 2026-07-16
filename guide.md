# guide.md: Streaming Attention Engine, Phases -1 to 1 (builder documentation)

Scope of this document: Phase -1 (toolchain smoke test), Phase 0 (bit-accurate
golden models), and the three completed, dual-countersigned RTL modules
(mac_unit, matmul_tile, online_softmax). attention_top is in progress and is
covered only by a status line; Phases 3 to 7 are listed as future work. Every
result claim in this document cites an EVIDENCE.md row id in brackets, for
example [EVIDENCE: verify-mac_unit]. Numbers not present in EVIDENCE.md cite
the repo artifact they were read from. No em dashes are used anywhere in this
file, per the project docs rule.

## 1. What this is

A fixed-point streaming attention accelerator in SystemVerilog: a tiled
Q.K^T matmul datapath (TPU-paper lineage) feeding an online softmax
(FlashAttention-paper lineage), with a bit-exact dual golden model
(Python and C++), cocotb simulation against that model, functional and line
coverage, lint, latch-free synthesis checks, and bounded formal proofs.

Honest status in one sentence: the three completed modules are verified in
simulation and formal; each is synthesized to a latch-free netlist (yosys
check, 0 problems); no static timing report exists yet (STA is Phase 4);
nothing is implemented on FPGA and nothing is fabricated (both are
PENDING-HARDWARE).

### 1.1 Status table

| Item | Status | Evidence |
|------|--------|----------|
| Phase -1: tool_smoke through the full verify pipeline | PASS | [EVIDENCE: verify-tool_smoke] |
| Phase 0: golden models bit-identical, LUT emitted, float gate met | PASS | [EVIDENCE: model-crosscheck] |
| rtl/mac_unit.sv | verify green, dual countersigned | [EVIDENCE: verify-mac_unit], [EVIDENCE: audit-mac_unit-lint-synth], [EVIDENCE: audit-mac_unit-formal-coverage] |
| rtl/matmul_tile.sv | verify green, dual countersigned | [EVIDENCE: verify-matmul_tile], [EVIDENCE: audit-matmul_tile-lint-synth], [EVIDENCE: audit-matmul_tile-formal-coverage] |
| rtl/online_softmax.sv | verify green, dual countersigned | [EVIDENCE: verify-online_softmax], [EVIDENCE: audit-online_softmax-lint-synth], [EVIDENCE: audit-online_softmax-formal-coverage] |
| rtl/attention_top.sv | IN PROGRESS: not yet built, not yet verified; no claims are made about it in this document | no row (none claimable) |
| Phases 3-7 (verification plan, STA, writeup, FPGA, GDS/silicon) | future work, see section 7 | no rows |

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
  SymbiYosys (sby) with the z3 SMT solver.
- Line coverage: the fraction of instrumented source lines executed at least
  once in simulation, from verilator --coverage, gated by
  scripts/check_coverage.py at line >= 90% and functional 100%.

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
| NUM   | Q10.21 | 32   | weighted-V accumulator (attention_top scope) |

Fixed configuration (docs/uarch.md section 1): D = 16 (head dimension), so
1/sqrt(D) = 1/4 is an exact right shift by 2 (D_SHIFT = 2) and the score path
needs no scaling multiplier; N_MAX = 256 (architectural), N <= 64 (project
default).

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
final output division (attention_top scope, docs/uarch.md 3.8) is specified
as a true integer divider rather than a reciprocal LUT plus multiply. The
scales are self-normalizing (num raw is value * 2^21, den raw is value *
2^15, so num_raw/den_raw is exactly the Q1.6 raw output with no pre- or
post-shift), the denominator is provably >= 2^15 so divide-by-zero cannot
occur, and a reciprocal table would add a multi-LSB relative error source
plus a second rounding site both golden models would have to replicate. The
divider is implemented and verified today only inside the two golden models
(this is a Phase 0 numeric-contract fact); its RTL belongs to attention_top,
which is not yet built.

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
generator output [EVIDENCE: audit-online_softmax-lint-synth], and the
online_softmax testbench re-checks all three renderings (attn.py in-memory
table, exp_lut.hex, exp_lut.svh) entry for entry plus the sha256 pin at
import time, before any simulation starts (tb/online_softmax/
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
attention_top). Per accepted score s it computes, in one cycle:

```
m_new = max(m, s)
r     = lut[ idx(m - m_new) ]     rescale factor, WGT UQ1.15
w     = lut[ idx(s - m_new) ]     this element's weight, WGT UQ1.15
l     <= rshr(l * r, 15) + w      DEN UQ9.15 (rounding site 3)
m     <= m_new
```

Ports, from rtl/online_softmax.sv:

```systemverilog
module online_softmax (
    input  logic               clk,
    input  logic               rst,        // synchronous, active-high
    input  logic               in_valid,   // accept score s this cycle
    input  logic               row_start,  // with in_valid: first element of a row
    input  logic signed [15:0] s,          // SCORE Q5.10
    output logic        [15:0] w,          // WGT UQ1.15, registered
    output logic        [15:0] r,          // WGT UQ1.15, registered
    output logic               out_valid,  // w, r valid (one cycle after accepted s)
    output logic        [23:0] l,          // DEN UQ9.15, current denominator
    output logic signed [15:0] m           // SCORE Q5.10, current running max
);
```

Timing contract: single-cycle recurrence, one element per cycle, no
backpressure; (m, l) update on the edge that consumes s and w, r, out_valid
register on the same edge, so during an out_valid cycle the visible l
already includes the element that (w, r) describe. Rows may be issued back
to back with no dead cycle (row_start with in_valid overrides the stale
state). The full cycle diagram is in docs/uarch.md 8.2 and is reproduced in
the RTL header comment.

### 6.2 Width and rounding derivation summary (normative: docs/uarch.md 3.3 to 3.6)

- SCORE Q5.10: |s| <= 4 * sqrt(D) = 16 for D = 16, needing 5 integer bits
  (Q5 spans [-32, 32)); 1 + 5 + 10 = 16 bits. The score conversion is ONE
  rounding step, s_raw = sat16((sacc_raw + 8) >> 4): scale 2^12 to 2^10 is
  >>2, divide by sqrt(16) = 4 is another >>2, combined >>4 with a single
  add-half (+8 = 2^3). Saturation is defensive only at D = 16: the max
  |s_raw| = (2^18 + 8) >> 4 = 2^14 = 16384 < 32767 (docs/uarch.md 3.3).
  This site lives UPSTREAM of this module (score-scale stage); the module
  consumes s already in SCORE format and contains no saturation.
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
  it) is what later guarantees the attention_top divider a nonzero
  denominator.
- Error placement: LUT index rounding bounds the per-weight relative error
  at e^(2^-7) - 1 = 0.784%; score quantization contributes 0.098% and
  entry quantization 0.0015%, so total eps0 <= 0.89% and the output bound
  is 2 * eps0 * (v_max - v_min) <= 4.6 LSB of Q1.6, inside the 6 LSB gate
  (docs/uarch.md section 7). The bound is loose worst-case; the recorded
  cross-check worst deviation is 0.77 LSB (section 3.2).

### 6.3 Microarchitecture

The complete combinational next-state and register blocks, pasted verbatim
from rtl/online_softmax.sv:

```systemverilog
  // All signals assigned unconditionally: no latches.
  always_comb begin
    m_base  = row_start ? MInit : m;
    l_base  = row_start ? 24'd0 : l;
    m_n     = (m_base >= s) ? m_base : s;
    diff_m  = 17'(m_base) - 17'(m_n);
    diff_s  = 17'(s) - 17'(m_n);
    idxp_r  = lut_index_pre(diff_m);
    idxp_w  = lut_index_pre(diff_s);
    idx_r   = (idxp_r > 11'd1023) ? 10'd1023 : idxp_r[9:0];
    idx_w   = (idxp_w > 11'd1023) ? 10'd1023 : idxp_w[9:0];
    r_n     = exp_lut_rom(idx_r);
    w_n     = exp_lut_rom(idx_w);
    // Rounding site 3: l = rshr(l * r, 15) + w. Bits above 23 of the shifted
    // value are provably zero for spec-compliant rows (l <= 2^23 by the 3.6
    // induction, r <= 2^15), and l_resc + w < 2^24 likewise; DEN carries no
    // saturation by policy (section 5), so the casts truncate nothing.
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

Flop count derivation: m (16) + l (24) + w (16) + r (16) + out_valid (1) =
73 flip-flops, and the auditor's independent synthesis re-run reports
exactly 73 FFs in the latch-free netlist
[EVIDENCE: audit-online_softmax-lint-synth]. The l * r intermediate is the
40-bit (24u x 16u) product of docs/uarch.md section 2 and is never
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
[EVIDENCE: verify-online_softmax].

Simulation (tb/online_softmax/test_online_softmax.py): 7 tests, all passing
on two seeds [EVIDENCE: audit-online_softmax-formal-coverage]. The golden
reference is imported DIRECTLY from model/attn.py (lut_index, rshr,
gen_exp_lut), not re-derived, so the TB cannot drift from the model:

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
   against attn_fixed's trace hook, the same golden model that will gate
   attention_top later.
7. random_control_fuzz: 2000 cycles of random in_valid/row_start/s against
   the mirror, checked every cycle, including hold behavior when
   in_valid = 0; row length capped at 60 to stay inside the N <= 256 DEN
   bound the width proof relies on.

ROM equivalence is additionally checked at TB import time, before any
simulation: exp_lut.hex vs exp_lut.svh vs gen_exp_lut() entry for entry,
plus the sha256 pin (section 3.3).

Coverage: 99.9% line coverage, and the sole missed point was investigated
and verified UNREACHABLE: it is the generated default arm of the exp_lut_rom
case statement, which a 10-bit index that is fully enumerated by 1024 case
arms can never select [EVIDENCE: audit-online_softmax-formal-coverage]. Raw
counters: tb/online_softmax/coverage.dat (1044 of 1045 points hit). This is
the honest reading of a coverage number: the gap is named, explained, and
shown to be dead by construction, not waved off.

Synthesis: lint clean, yosys check 0 problems (build/synth.log, yosys
0.52), no $_DLATCH_, netlist latch-free at 73 FFs, arithmetic verified
against docs/uarch.md sections 6 and 3.5, and the generated ROM confirmed
diff-identical to the emitter output
[EVIDENCE: audit-online_softmax-lint-synth].

Formal (formal/online_softmax.sby: BMC, depth 20, smtbmc z3): PASS,
audited non-vacuous, in 4 seconds of solver time
(formal/online_softmax/logfile.txt)
[EVIDENCE: audit-online_softmax-formal-coverage]. Proven for every input
sequence to depth 20: the clamp facts (diff_m <= 0, diff_s <= 0, pre-clamp
indices <= 1024, final indices <= 1023, as combinational assertions); reset
state (m = -32768, l = 0, out_valid = 0); hold when in_valid was low (m, l,
w, r unchanged and no stale out_valid pulse); out_valid rises exactly one
cycle after each accepted element; on a row_start step m becomes exactly
the incoming s (identity 2, max part); otherwise m is monotone
non-decreasing within a row.

The formal-is-a-subset split, stated exactly (from the .sby header and
CLAUDE.md): the BMC transition relation CONTAINS the 1024-entry ROM
function and the 24u x 16u multiply (they feed the asserted registers), but
no property asserts ROM contents or product values, because an open-source
BMC flow proving a 40-bit multiply and a 1024-way ROM functionally correct
is exactly the proof this toolchain cannot do in reasonable time. Those
checks are deliberately pushed to cocotb: LUT entry-for-entry equivalence
(rom_full_sweep plus the import-time triple check), the full recurrence
against the model/attn.py mirror on every cycle, and the DEN bound over
long random rows. The alignment (out_valid/w/r/l element consistency) and
rescale-identity checks were specifically audited
[EVIDENCE: audit-online_softmax-formal-coverage].

### 6.5 Known gaps

- Formal does not prove ROM contents, multiplier correctness, or the DEN
  induction bound; simulation carries those (see the split above). This is
  a documented toolchain-driven scope decision, not an oversight.
- Line coverage is 99.9%, not 100%; the single miss is the unreachable
  generated default case arm, verified dead by construction
  [EVIDENCE: audit-online_softmax-formal-coverage].
- The single-cycle path diff -> clamp -> index -> ROM -> (l * r multiply)
  -> rshr -> add is the expected critical path of the whole design; no STA
  has been run yet (Phase 4), and docs/uarch.md 8.2 already reserves a
  registered-ROM pipelining variant if timing requires it. No Fmax number
  is claimed anywhere in this document because no timing report exists.

## 7. Status and roadmap

### 7.1 The sandbox/silicon wall, restated

Everything claimed above is sandbox-provable: simulation, coverage, lint,
synthesis to a netlist, and bounded formal. The three completed modules are
verified in simulation and formal and synthesized to latch-free netlists;
they are not implemented on FPGA and nothing is fabricated. There is no
measured Fmax, no bench power number, and no hardware bring-up result in
this project yet, and none is claimed.

| Item | Status |
|------|--------|
| attention_top (Phase 2) | IN PROGRESS: not yet built, not yet verified; no technical claims made |
| Phase 3: coverage model expansion + SVA plan (docs/verification_plan.md) | future work |
| Phase 4: synthesis + OpenSTA timing report, one pipelining iteration | future work (no Fmax exists yet) |
| Phase 5: verification plan + power proxy + tradeoffs writeup | future work |
| Phase 6: FPGA bring-up | PENDING-HARDWARE (needs a real board and user bench evidence) |
| Phase 7: OpenLane RTL-to-GDS + VCD power estimate | future work (sandbox) |
| Phase 7: TinyTapeout silicon | PENDING-HARDWARE (not taped out; needs user evidence) |

### 7.2 Stage-gated resume bullets

Only the following bullets are currently claimable, each clause mapped to
its evidence. The bracketed clauses are the load-bearing ones.

Bullet 1 (claimable now): "Built a bit-exact dual golden model (Python and
C++) for a fixed-point streaming attention engine [and proved them
byte-identical across 14 random and corner cases including N = 256, with a
derivation-backed error budget met at 0.77 LSB worst case against float]."

| Clause | Evidence |
|--------|----------|
| dual golden model, byte-identical, 14 cases | [EVIDENCE: model-crosscheck], model/crosscheck.py |
| error budget met, 0.77 LSB worst case | [EVIDENCE: model-crosscheck], docs/uarch.md section 7 |

Bullet 2 (claimable now): "Designed and verified the attention core
datapath in SystemVerilog (MAC, 4x4 output-stationary matmul tile, online
softmax) [each passing cocotb simulation against the golden model on
multiple seeds, 100%/100%/99.9% line coverage, latch-free yosys synthesis,
and SymbiYosys bounded proofs, all independently re-run and countersigned
by two auditors]."

| Clause | Evidence |
|--------|----------|
| mac_unit verified, 4/4 tests, 100% coverage, latch-free, BMC PASS | [EVIDENCE: verify-mac_unit], [EVIDENCE: audit-mac_unit-lint-synth], [EVIDENCE: audit-mac_unit-formal-coverage] |
| matmul_tile verified, 6/6 tests two seeds, 100% coverage, 384 FF latch-free, depth-5 BMC non-vacuous | [EVIDENCE: verify-matmul_tile], [EVIDENCE: audit-matmul_tile-lint-synth], [EVIDENCE: audit-matmul_tile-formal-coverage] |
| online_softmax verified, 7/7 tests two seeds, 99.9% coverage (sole miss unreachable), 73 FF latch-free, depth-20 BMC non-vacuous | [EVIDENCE: verify-online_softmax], [EVIDENCE: audit-online_softmax-lint-synth], [EVIDENCE: audit-online_softmax-formal-coverage] |

Interim voice for anything further: verified in simulation and formal;
synthesized to a latch-free netlist; not implemented on FPGA, not taped
out. No FPGA, timing, power, or silicon bullet exists yet because no
evidence row exists for any of them.

## 8. Reproduce it yourself

All commands run from the repo root (/home/owner/p1-attention). The verify
targets append their own EVIDENCE.md rows on success.

```
# Phase -1: prove the toolchain before trusting any RTL result
make verify MODULE=tool_smoke COVERAGE_STUB=1

# Phase 0: golden models bit-identical + float gate (14 cases)
make model-check

# Per-module full gates (each runs lint, sim, coverage, synth-check, formal)
make verify MODULE=mac_unit
make verify MODULE=matmul_tile
make verify MODULE=online_softmax

# Individual stages, if you want to see one gate at a time
make lint        MODULE=online_softmax
make sim         MODULE=online_softmax SEED=1
make sim         MODULE=online_softmax SEED=7   # different stimulus, same pass
make coverage
make synth-check MODULE=online_softmax          # writes build/synth.log
make formal      MODULE=online_softmax          # writes formal/online_softmax/

# Regenerate the LUT artifacts from the single source (should be no-ops)
python3 model/attn.py --emit-lut model/exp_lut.hex
python3 model/attn.py --emit-lut-svh rtl/exp_lut.svh

# Audit this document for unbacked hardware claims
make audit-guide
```

Key artifacts to inspect: EVIDENCE.md (the claim ledger), docs/uarch.md
(the normative numeric contract), build/synth.log and build/synth_full.log
(yosys check and latch passes), tb/<module>/coverage.dat (raw coverage
counters), formal/<module>/logfile.txt (sby proof logs), and
tb/<module>/results.xml (cocotb results).
