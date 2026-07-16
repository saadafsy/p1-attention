# Verification plan: Streaming Attention Engine

Status of this document: Phase 5 deliverable (P1_Attention_Engine_Build_Sheet.md,
PHASE 5), retroactively formalized. mac_unit, matmul_tile, and online_softmax were
built and verified first (Phase 1); this document writes down, as a living plan, the
strategy that already produced their EVIDENCE.md PASS rows, and states the plan (not
yet a result) for attention_top, which is still in progress. Every claim about a
completed module cites an EVIDENCE.md row id in brackets, for example
[EVIDENCE: verify-mac_unit]. Claims about attention_top are written in plan voice only,
because no EVIDENCE.md row exists for it yet; see section 6. No em dashes are used
anywhere in this file, per the project docs rule.

## 1. Features under verification, per module

Each row maps a checked feature to the docs/uarch.md section that is its normative
definition. docs/uarch.md is the source of truth; if code and that file disagree, the
code is the bug (docs/uarch.md, header).

### 1.1 mac_unit

| Feature | uarch.md section |
|---------|-------------------|
| Control contract: rst > clr > en priority, load-not-add-to-garbage on clr&&en | 8.1 (table), rtl/mac_unit.sv |
| ACT x ACT product, exact (no rounding) | 2, 3.2 |
| SACC accumulate, 24-bit Q11.12, no saturation, overflow impossible for D <= 511 | 3.2 |
| 24-bit register wrap behavior at the D > 511 boundary (out-of-spec, pins the width) | 3.2 |

### 1.2 matmul_tile

| Feature | uarch.md section |
|---------|-------------------|
| Packing convention: q_flat/k_flat little-endian element slicing, acc_flat row-major | 8.1 |
| Broadcast wiring: Q row i across grid row i, K row j down grid column j (not swapped) | 8.1 |
| Shared control (rst, clr, en) re-exported unchanged to all 16 mac_units | 8.1 |
| 24-bit per-element wrap and the in-spec (D=16) no-overflow bound | 3.2, 8.1 |

### 1.3 online_softmax

| Feature | uarch.md section |
|---------|-------------------|
| Recurrence: m_new = max(m, s); r = lut[idx(m - m_new)]; w = lut[idx(s - m_new)]; l update | 6, 8.2 |
| exp LUT: 1024 x 16-bit direct-mapped ROM, single generation source | 3.5, 8.2 |
| Diff clamp (max(d, -16384)) and LUT index clamp (min(idx, 1023)) | 5, 3.5 |
| DEN (l) no-overflow bound by induction, including the rounding term | 3.6 |
| row_start basis override and back-to-back row issue with no dead cycle | 8.2 |
| Rescale identities: r = 0x8000 is an exact identity; first-element state is exact | 6.1 |

### 1.4 attention_top (in progress, no EVIDENCE row yet; plan only, see section 6)

| Feature (planned) | uarch.md section |
|--------------------|-------------------|
| End-to-end recurrence vs model/attn.py attn_fixed, bit-exact | 8.3, 6 |
| FSM: S_IDLE / S_COMPUTE / S_DRAIN_LAST / S_DIVIDE, busy/done contract, cycle_count formula | 8.3 |
| Round-robin drain addressing and drain_buf same-edge capture (the d=15 correction) | 8.3 |
| Output divider bank: 3.8 algorithm, sign correction, sat8 | 3.8, 8.3 |

## 2. Stimulus strategy

Three layers, applied to every module in build order (mac_unit -> matmul_tile ->
online_softmax -> attention_top, CLAUDE.md build order):

1. **Directed tests**: hand-computed values and named corner cases (reset, hold,
   clr-without-en, extreme operand magnitudes, the exact width-wrap boundary). These
   pin down cases too rare for random stimulus to reliably hit, such as mac_unit's
   511-term/512-term wrap boundary (docs/uarch.md 3.2) and online_softmax's LUT
   zero-tail boundary at index 709/710 (docs/uarch.md 3.5).
2. **Golden-model compare**: every test, directed or random, checks the RTL against a
   bit-exact mirror built from model/attn.py (never re-derived; see section 3).
3. **Constrained-random with functional coverage bins**: online_softmax additionally
   has a Phase 3 coverage model, tb/online_softmax/test_softmax_coverage.py, that
   extends tb/online_softmax/ (per the build brief, it does not re-derive or replace
   the existing checkers). Its own module docstring states the motivating gap it
   closes: "no existing test approaches the DEN worst case: l reaches only ~2^21 in
   tb/online_softmax/test_online_softmax.py's longest rows (length <= 64), while a
   256-element constant-score row hits l = 2^23 exactly, exercising l bits [23:22]
   that plain line coverage cannot see." The coverage model itself is a plain
   Python dict-of-counters (no external coverage library), with bins defined in
   COV.GROUPS over score value, diff_w classification, LUT index (both w and r
   paths), rescale factor, l value, row length, control sequencing, and three cross
   bins, each motivated by a specific docs/uarch.md equation (3.5, 3.6, 6, 6.1, 8.2
   per the file's own docstring).

   Result, from tb/online_softmax/func_coverage.txt:

   ```
   online_softmax functional coverage report
   seed: 930562133127031167032121786563323809980319571174
   TOTAL: 52/52 reachable bins hit (100.0%), 1 documented-unreachable, 53 bins defined
   ```

   The one documented-unreachable bin, with its reason, verbatim from the same file:

   ```
   diff_w.positive_impossible: diff_w = s - m_new can never be > 0: m_new = max(m_base, s) by construction (docs/uarch.md section 6), so s <= m_new always and diff_w <= 0 for every accepted element. Asserted structurally (never attempted), and also asserted directly in the RTL FORMAL block (rtl/online_softmax.sv: assert (diff_s <= 17'sd0);).
   ```

   Functional closure for this module is therefore: all reachable bins hit, plus
   exactly one bin proven structurally unreachable (backed independently by the RTL's
   own formal assertion `assert (diff_s <= 17'sd0);`), and zero unhit reachable bins
   (the file's own "Unhit reachable bins (coverage gap, should be empty at closure):
   (none)" line) [EVIDENCE: audit-online_softmax-formal-coverage].

### Seed discipline

The Makefile's `sim` target takes `SEED` and passes it through as `COCOTB_RANDOM_SEED`
to cocotb, which (cocotb 2.0.1) hashes the test's full name together with that env var
and reseeds Python's global `random` module per test before the test body runs. The
project's discipline is that every module's random-number generators must be built
from `cocotb.RANDOM_SEED` (a `seeded_rng()` helper, one per testbench file) so that
`SEED=1` vs `SEED=7` provably changes stimulus rather than silently reusing the same
sequence. Verify runs a module on two genuinely different seeds before it is
considered green.

mac_unit is the one documented exception, and the gap is carried forward honestly
rather than hidden: its testbench RNGs are fixed literals, `random.Random(2)` and
`random.Random(3)`, so the Makefile's `SEED` variable does not change mac_unit's
random stimulus; the auditor's two-seed re-run for mac_unit therefore repeated
identical random tests [EVIDENCE: audit-mac_unit-formal-coverage]. The finding was
fixed in every later testbench: tb/matmul_tile/test_matmul_tile.py and
tb/online_softmax/test_online_softmax.py both build every RNG as
`random.Random(cocotb.RANDOM_SEED)` inside a `seeded_rng()` helper (with a fallback
only if the attribute is somehow absent), documented in each file's own module
docstring as a "mandatory carried-forward auditor finding." Both modules' two-seed
re-runs (SEED=1, SEED=7) therefore provably exercise different random stimulus
[EVIDENCE: audit-matmul_tile-formal-coverage], [EVIDENCE: audit-online_softmax-formal-coverage].

## 3. Checkers

The single highest-risk bug class in fixed-point work is a silent rounding semantics
mismatch (Python `>>`/`//` floor on negative numbers; C++ `/` truncates toward zero).
To avoid a testbench re-deriving the wrong rounding a second time, every module
testbench imports its golden checker DIRECTLY from model/attn.py rather than
reimplementing the arithmetic:

- tb/mac_unit: mirror model is the control contract (rst > clr > en) with 24-bit
  two's complement wrap, the exact inner loop of model/attn.py `attn_fixed`'s SACC
  accumulation (module docstring, tb/mac_unit/test_mac_unit.py).
- tb/matmul_tile: mirror model is the mac_unit control contract applied independently
  to all 16 (i, j) accumulators (module docstring, tb/matmul_tile/test_matmul_tile.py).
  `golden_dot()` asserts the docs/uarch.md 3.2 bound `|sacc| < 2^23` on every reference
  value it produces, so the checker itself cannot silently emit an out-of-spec
  reference.
- tb/online_softmax: the `SoftmaxMirror` class and the `softmax_step()` helper are
  "built directly from model/attn.py's lut_index/rshr/gen_exp_lut -- those ARE the
  golden reference, not re-derived here" (module docstring,
  tb/online_softmax/test_online_softmax.py). `softmax_step()` asserts the DEN width
  bound (`0 <= l < 2^24`, docs/uarch.md 3.6) on every call, not just at the end of a
  row. tb/online_softmax/test_softmax_coverage.py explicitly does not re-derive the
  golden model either: it imports `SoftmaxMirror`, `softmax_step`, `drive_and_check`,
  and `start_and_reset` from test_online_softmax and states in its own docstring that
  "the coverage model below only OBSERVES the values that check already computed, it
  does not weaken or replace it."
- tb/attention_top (in progress): the planned checker is `model/attn.py`'s
  `attn_fixed`, "the SAME bit-exact golden reference used by tb/online_softmax and
  model/crosscheck.py. No re-derivation of the recurrence here: attn_fixed IS the
  contract" (module docstring, tb/attention_top/test_attention_top.py).

Every checker does an every-cycle comparison, not just an end-of-transaction check:
tb/mac_unit's `random_control_fuzz` and tb/matmul_tile's `random_control_fuzz` compare
every cycle against their software mirror; tb/online_softmax's
`full_row_golden_compare` compares `(m, l, w, r, out_valid)` against the mirror "EVERY
cycle, not just at row boundaries" (test docstring); tb/attention_top's `run()` helper
checks the busy/done handshake shape every cycle inside the run (module docstring).

Width asserts mirror the RTL's own declared register widths, not looser bounds:
mac_unit and matmul_tile mirrors wrap at 24 bits (the same width as `acc`/`acc_flat`
elements); the online_softmax mirror asserts `0 <= l < 2^24` (the same declared range
as the `l` register, docs/uarch.md 3.6) on every step, so a checker-side width bug
cannot mask an RTL width bug or vice versa.

## 4. Coverage goals and actuals

Line coverage gate: `scripts/check_coverage.py --line 90 --func 100` (from the
Makefile's `coverage` target), invoked by `make coverage` inside `make verify`. The
gate requires line coverage >= 90% and full functional-bin closure (100% of the
functional model that exists for a module, or every miss documented-unreachable).

| Module | Line coverage (actual) | Source |
|--------|--------------------------|--------|
| mac_unit | 100% (8/8 instrumented points hit) | tb/mac_unit/coverage.dat [EVIDENCE: audit-mac_unit-formal-coverage] |
| matmul_tile | 100% | tb/matmul_tile/coverage.dat [EVIDENCE: audit-matmul_tile-formal-coverage] |
| online_softmax | 99.9% (1044 of 1045 points hit) | tb/online_softmax/coverage.dat [EVIDENCE: audit-online_softmax-formal-coverage] |

The online_softmax 99.9% figure is not a shortfall waved off: the sole miss is the
generated default arm of the `exp_lut_rom` case statement, which a fully enumerated
10-bit index (1024 case arms) can never select, so the arm is dead by construction.
This was independently re-verified by the formal-coverage auditor
[EVIDENCE: audit-online_softmax-formal-coverage].

Functional closure, per module:

- mac_unit and matmul_tile: no separate functional coverage model exists yet beyond
  the directed corner list in section 2; their line coverage is 100% and their
  directed tests enumerate every control-contract row of the tables in
  docs/uarch.md 8.1.
- online_softmax: 52/52 reachable functional bins hit (100%), 1 bin documented
  unreachable with a structural reason backed by an RTL formal assertion (section 2,
  reproduced from tb/online_softmax/func_coverage.txt)
  [EVIDENCE: audit-online_softmax-formal-coverage]. Functional closure for this
  module is defined as: every reachable bin hit, every unreachable bin named and
  proven unreachable (not merely unhit), and zero bins in the "unhit reachable"
  category.
- attention_top: no coverage model exists yet; this is future work for when the
  module reaches verify-green (section 6).

## 5. Formal strategy

### 5.1 The formal-is-a-subset split (CLAUDE.md "formal is a subset / do not fight
the tool")

Open-source `sby`/`smtbmc`/z3 proves simple SVA over a bounded number of cycles well;
it does not economically prove wide multipliers or large ROMs functionally correct.
The project's fixed policy is therefore: keep formal properties minimal and
solver-cheap (reset, control priority, clamp facts, monotonicity, mutual exclusion),
and push all rich numerical checking (LUT entry-for-entry equivalence, the full
recurrence against the golden model, accumulator overflow bounds over long random
runs) into cocotb. This split is stated in the header comment of every `.sby` file in
formal/ and is restated below per module.

### 5.2 Per-module property lists

**mac_unit** (formal/mac_unit.sby, BMC depth 20, smtbmc z3): the FORMAL block in
rtl/mac_unit.sv restates the five-row control contract (reset, clr-without-en,
clr-and-en load, accumulate, hold) as immediate assertions over `$past` values,
recomputing `$past(a) * $past(b)` with the same operator the datapath uses. What this
proves: register/control behavior for ALL input sequences to depth 20. What it does
NOT prove: that SystemVerilog multiplication equals mathematical multiplication
(that is simulation's job, via the golden-model dot products)
[EVIDENCE: verify-mac_unit], [EVIDENCE: audit-mac_unit-formal-coverage].

**matmul_tile** (formal/matmul_tile.sby, BMC depth 5, smtbmc z3): proven at tile
level, for all input sequences to depth 5: reset drives all 384 `acc_flat` bits to 0;
clr-without-en drives all 384 bits to 0; hold leaves `acc_flat` unchanged; and one
representative datapath element, (0,0), recomputes both the clr-and-en load and the
accumulate against the exact q*k product. Deliberately NOT covered by formal after
the reduction below: the datapath of the other 15 elements (covered exhaustively by
cocotb instead) [EVIDENCE: verify-matmul_tile],
[EVIDENCE: audit-matmul_tile-formal-coverage].

**online_softmax** (formal/online_softmax.sby, BMC depth 20, smtbmc z3): proven for
every input sequence to depth 20: idx() clamp facts (`diff_m <= 0`, `diff_s <= 0`,
pre-clamp and final LUT indices in their declared ranges); reset state
(`m == -32768`, `l == 0`, `out_valid == 0`); hold behavior when `in_valid` was low
(state unchanged, no stale `out_valid` pulse); `out_valid` rises exactly one cycle
after each accepted element; on a `row_start` step `m` becomes exactly the incoming
`s` (identity 2); otherwise `m` is monotonic non-decreasing within a row. NOT proven:
ROM contents, the 40-bit multiply's numerical correctness, or the DEN no-overflow
induction bound; those are cocotb's job (`rom_full_sweep`, `full_row_golden_compare`,
and the DEN assert inside `softmax_step()`) [EVIDENCE: verify-online_softmax],
[EVIDENCE: audit-online_softmax-formal-coverage].

**attention_top** (formal/attention_top.sby exists in the repo; BMC depth 10, smtbmc
z3; PLANNED scope, no EVIDENCE row yet, see section 6): the property list is
control-only, per the .sby header comment and docs/uarch.md 8.3's own "FORMAL block"
paragraph: reset state (`S_IDLE`, `busy=0`, `done=0`, `cycle_count=0`), busy/done
mutual exclusion, done implies idle, `cycle_count` monotone non-decreasing while busy.
None of these properties reference `q_mem`/`k_mem`/`v_mem`/`out_mem`, the NUM
accumulators, the score/rescale arithmetic, or the divider bank, because the control
FSM's transition conditions depend only on counters (`t`, `kb`, `rg`, `row`,
`div_cnt`) and `start`, never on datapath values.

### 5.3 The chformal reductions, and their justification chain

| .sby file | Strips assertions from | Justification |
|-----------|--------------------------|----------------|
| formal/matmul_tile.sby | `mac_unit` | The 16 mac_unit instances are wired identically by the same generate body; the contract is already proven standalone at depth 20 (formal/mac_unit.sby, PASS, auditor-countersigned). Re-proving 16 replicated copies of an identical contract inside the tile-level BMC is redundant solver load for zero additional coverage. |
| formal/attention_top.sby | `mac_unit`, `matmul_tile`, `online_softmax` | All three submodules are instantiated in attention_top UNMODIFIED (docs/uarch.md 8.3's own words); each contract is already proven standalone and auditor-countersigned (formal/mac_unit.sby, formal/matmul_tile.sby, formal/online_softmax.sby, all PASS). Re-proving them again inside the integration-level BMC would be redundant for zero additional coverage, and the full unstripped netlist (3 RAMs, a ROM, 16+16 multipliers, a 16-wide divider bank, plus the three submodules' own BMC-heavy assertions) is stated in the .sby header to be "far past what open smtbmc/z3 proves in a reasonable budget." |

The matmul_tile reduction was independently audited: the formal-coverage auditor
re-ran the proof, inspected the generated SMT2 to confirm the remaining assertions
are non-vacuous, and countersigned the reduction as justified
[EVIDENCE: audit-matmul_tile-formal-coverage]. The attention_top reduction has not
yet been through an equivalent audit pass because the module is not yet
verify-green (section 6); auditing that reduction is part of the sign-off gate that
remains to be run.

### 5.4 Accepted gaps

- mac_unit: BMC depth 20 covers the control contract as a one-cycle relation over
  `$past`; multi-hundred-cycle accumulations (the 511-term width-edge case) are
  simulation-only, not formal
  [EVIDENCE: audit-mac_unit-formal-coverage].
- matmul_tile: per-element datapath assurance for 15 of the 16 grid elements is
  simulation-only by design (section 5.2)
  [EVIDENCE: audit-matmul_tile-formal-coverage].
- online_softmax: formal does not prove ROM contents, multiplier correctness, or the
  DEN induction bound (section 5.2)
  [EVIDENCE: audit-online_softmax-formal-coverage].
- PLANNED, not done: an exact-max property. Today the three width/overflow bounds
  that matter most (mac_unit's SACC bound at D <= 511, docs/uarch.md 3.2; the DEN
  induction bound, docs/uarch.md 3.6; the NUM bound, docs/uarch.md 3.7) are each a
  paper derivation, checked at runtime by an assert in both golden models, and pinned
  by a directed simulation test that walks up to the exact width-wrap boundary (for
  example mac_unit's 511-term/512-term test and matmul_tile's derived 517-term
  24-bit-wrap crossing, guide.md section 5.4). No `.sby` file in formal/ currently
  contains a BMC induction property that proves the exact numeric boundary itself
  (for example, that `l_raw <= j * 2^15` holds for all reachable `j`, or that the
  384-bit accumulator bus can never reach the exact overflow value for any reachable
  input sequence) as a machine-checked induction rather than a paper proof plus a
  runtime assert plus a directed test. Adding such a property, and auditing it for
  non-vacuousness the same way the existing chformal reductions were audited, is
  future work; no EVIDENCE.md row exists for it and none is claimed here.

## 6. Sign-off criteria per module

A module reaches [Done] in PLAN.md, and its EVIDENCE.md rows may be cited as PASS in
project documentation, only when ALL of the following hold (CLAUDE.md "Definition of
Done"):

1. `make verify MODULE=<name>` exits 0: lint (verilator + verible), sim (cocotb vs
   golden on the accepted seed set), coverage gate (`scripts/check_coverage.py`),
   synth-check (yosys, latch-free), and formal (`sby`), in that order.
2. A `verify-<name>` PASS row is appended to EVIDENCE.md by the `verify` Makefile
   target itself (not hand-written).
3. Both auditor roles independently re-run and countersign: the lint-synth auditor
   (independent lint/synth-check/yosys re-run) and the formal-coverage auditor
   (independent multi-seed sim re-run, coverage re-check, and sby re-run with SMT2
   inspection of any chformal reduction). Each countersign is its own EVIDENCE.md row.
4. Only after 1 to 3 does the user's own from-scratch replication ("grill me", Mode B
   of the technical-writer) happen, per CLAUDE.md and PLAN.md's own rule: "Only Lead
   moves a task to [Done], and only after: make verify exits 0, an EVIDENCE row
   exists, a Beta auditor countersigned, AND I passed 'grill me'."

Applied to the modules built so far: mac_unit, matmul_tile, and online_softmax have
all cleared steps 1 to 3 [EVIDENCE: verify-mac_unit],
[EVIDENCE: audit-mac_unit-lint-synth], [EVIDENCE: audit-mac_unit-formal-coverage],
[EVIDENCE: verify-matmul_tile], [EVIDENCE: audit-matmul_tile-lint-synth],
[EVIDENCE: audit-matmul_tile-formal-coverage], [EVIDENCE: verify-online_softmax],
[EVIDENCE: audit-online_softmax-lint-synth],
[EVIDENCE: audit-online_softmax-formal-coverage].

### 6.1 attention_top (plan only; verification is in flight)

No EVIDENCE.md row exists for attention_top and no result is claimed about it in this
document. The repo already contains a testbench under development
(tb/attention_top/test_attention_top.py) and a formal setup
(formal/attention_top.sby); this section states the PLAN those artifacts are built
toward, not an outcome.

The plan, once the module reaches verify-green, is to check:

- **End-to-end golden compare across n in {4, 8, 16, 32, 64}**: one seeded-random
  case per size, full N x D output compare, bit-exact against `model/attn.py
  attn_fixed`, in the same test that also checks cycle-formula equality (planned
  test `end_to_end_golden`).
- **Cycle-formula equality**: `cycle_count` checked against the closed-form
  `nblk*(16*nblk+156)+1` (docs/uarch.md 8.3) on every run, not only at n = 64, per
  the module's own `cycle_formula()` helper.
- **Corners**: all-zeros, all +127, all -128, V-extremes with random Q/K, and the
  `monotonic_case` stimulus from model/crosscheck.py (the same max-update stress
  pattern used to gate the golden models themselves, now driven through the whole
  integrated stack) (planned test `corners`).
- **Mid-run reset**: `rst` asserted 300 cycles into an n = 64 (6593-cycle) run, then
  checking the FSM returns to idle (`busy` drops, `done` stays low, `cycle_count`
  clears) and that a subsequent clean run still computes bit-exactly (planned test
  `rst_mid_run`).
- **Back-to-back runs**: two different cases run without an intervening `rst`,
  checking that all state (RAMs, each lane's online_softmax (m, l) state, the NUM
  accumulators, and the FSM's own counters) fully reinitializes from the start pulse
  alone (planned test `multi_run_no_reset`).
- **Formal, control-only, inner-module asserts stripped**: the property list and the
  three-way chformal reduction of section 5.2/5.3, over `formal/attention_top.sby`.

Sign-off for attention_top follows the same four-step gate as section 6: `make
verify MODULE=attention_top` exit 0, an EVIDENCE.md PASS row, dual auditor
countersign, and the user's Mode-B replication grill, in that order. Until step 1
happens, PLAN.md's row for attention_top stays [Todo]/[Building] and this document
makes no claim that any of the planned checks above currently passes.

## 7. The sandbox/silicon wall, for hardware phases

Everything above (lint, simulation, functional and line coverage, synthesis to a
gate-level netlist, and bounded formal proof) is sandbox-provable on this machine and
may be stated as a result once its EVIDENCE.md row exists. Phases 6 and 7 introduce
claims that need a real board or fabricated silicon, and those stay PENDING-HARDWARE
until bench evidence is supplied, per CLAUDE.md's non-negotiable rule:

> Anything needing a real FPGA board or silicon (measured Fmax on hardware, bench
> power, "runs on the board", "taped out") stays PENDING-HARDWARE until I supply
> evidence. Interim voice: "verified in simulation and formal; synthesized to a
> latch-free netlist meeting timing at <Fmax from report> in <tool>; not implemented
> on FPGA / not taped out."

Concretely for this project: Phase 6 (FPGA bring-up on a Basys 3, docs/phase6_fpga_guide.md)
is [Blocked: needs bench] in PLAN.md, and its own guide states plainly, "NOTHING IN
THIS DOCUMENT HAS BEEN EXECUTED... Until then the only honest claim remains: verified
in simulation and formal; synthesized to a latch-free netlist; not implemented on
FPGA." Phase 7's GDS/layout/power-estimate work (docs/phase7_physical_guide.md) is
sandbox-achievable and will get its own EVIDENCE rows when run; TinyTapeout
fabrication is explicitly PENDING-HARDWARE plus money, per that guide's own claim
ledger: "Chip on desk + clock sweep | 'fabricated and characterized on silicon' |
PENDING-HARDWARE until the chip is measured." No FPGA, timing-on-hardware, power, or
silicon claim appears anywhere in this document, and none should appear in any future
revision of it without a corresponding EVIDENCE.md row.
