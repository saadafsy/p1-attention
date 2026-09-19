# Verification plan: Streaming Attention Engine

Status of this document: Phase 5 deliverable (P1_Attention_Engine_Build_Sheet.md,
PHASE 5), retroactively formalized, refreshed 2026-09-18 to the ledger state (the
previous revision still described attention_top as unverified and the exact-max
property as planned; review finding M3/F006). All four RTL modules have verify-green
EVIDENCE.md rows and dual auditor countersigns; every claim about a completed module
cites an EVIDENCE.md row id in brackets, for example [EVIDENCE: verify-mac_unit].
Where the 2026-09-18 review changed a gate or a proof, the section says what was
measured before and what the gate now requires. No em dashes are used anywhere in
this file, per the project docs rule.

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

### 1.4 attention_top ([EVIDENCE: verify-attention_top], [EVIDENCE: audit-attention_top-lint-synth], [EVIDENCE: audit-attention_top-formal-coverage])

| Feature | uarch.md section |
|---------|-------------------|
| End-to-end recurrence vs model/attn.py attn_fixed, bit-exact | 8.3, 6 |
| FSM: S_IDLE / S_COMPUTE / S_DRAIN_LAST / S_DIVIDE, busy/done contract, cycle_count formula | 8.3 |
| Round-robin drain addressing and drain_buf same-edge capture (the d=15 correction) | 8.3 |
| Output divider bank: 3.8 algorithm, sign correction, sat8 | 3.8, 8.3 |
| Shared 16-wide PV datapath driven by a one-hot lane select (2026-09-18 rewrite, re-verification pending) | 8.3 |
| n_len contract corners: non-power-of-two group counts, sel=3, start-while-busy (tests added 2026-09-18, not yet run) | 8.3 |

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

mac_unit was the one documented exception: its testbench RNGs were fixed literals,
`random.Random(2)` and `random.Random(3)`, so the Makefile's `SEED` variable did not
change mac_unit's random stimulus and the auditor's two-seed re-run repeated
identical random tests [EVIDENCE: audit-mac_unit-formal-coverage]. Fixed 2026-09-18
(seeded_rng() in tb/mac_unit/test_mac_unit.py), not yet re-run. The finding had
already been fixed in every later testbench: tb/matmul_tile/test_matmul_tile.py and
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
- tb/attention_top: the checker is `model/attn.py`'s `attn_fixed`, "the SAME
  bit-exact golden reference used by tb/online_softmax and model/crosscheck.py. No
  re-derivation of the recurrence here: attn_fixed IS the contract" (module
  docstring, tb/attention_top/test_attention_top.py), applied to every output byte
  of every run [EVIDENCE: audit-attention_top-formal-coverage].

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

Line coverage gate: `scripts/check_coverage.py --line 90 --func 100 --module M`
(from the Makefile's `coverage` target), invoked inside `make verify`. The gate
requires line coverage >= 90% and full functional-bin closure (100% of the
functional model that exists for a module, or every miss documented-unreachable).

Gate correction (2026-09-18, review finding F004): until that date the script
counted every verilator `C` record, pooling `t=branch` points into the "line"
percentage. Re-parsed with `t=line` only, the artifacts that were tracked at the
time read:

| Module | Line points (t=line only) | Branch points | Pooled figure the old gate printed |
|--------|---------------------------|---------------|------------------------------------|
| mac_unit | 2/2 | 6/6 | 8/8 = 100% |
| matmul_tile | 2/2 | 6/6 | 8/8 = 100% |
| online_softmax (default) | 1029/1030 | 16/16 | 1045/1046 = 99.9% |
| attention_top | 46/53 = 86.8% | 98/98 | 144/151 = 95.4% |

attention_top's true line coverage was therefore BELOW the 90% gate and passed only
by pooling. Its seven unhit lines are the defensive saturation arms and the
`default:` case arms the auditor had already judged unreachable
[EVIDENCE: audit-attention_top-formal-coverage]; they are now declared, one per
line with a reason, in tb/attention_top/coverage_waivers.txt, and the gate prints
raw, waived and effective figures (effective 46/46). The online_softmax miss (the
generated ROM default arm, dead by construction because a 10-bit index is fully
enumerated by 1024 case arms [EVIDENCE: audit-online_softmax-formal-coverage]) is
likewise a declared waiver. Waivers that match no unhit point fail the gate, so they
cannot rot. coverage.dat files are generated per run and no longer tracked.

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
- attention_top: a 22-bin functional model was added 2026-09-18 (n_len classes
  including the non-power-of-two counts 12/20/36, control corners: back-to-back
  runs, mid-run reset, start-while-busy ignored, sel=3 ignored; input/output
  extremes; readback), observed from stimulus and outputs and written to
  tb/attention_top/func_coverage.txt by the last test, gated with --func 100. It has
  not yet been run; until it has, this row states the model, not a closure result.
- PIPE_ROM = 1 (online_softmax): its 6 structural bins are now recorded from observed
  mirror state on every cycle (they were unconditional hit() calls before
  2026-09-18, review finding M7), and the run's own line-coverage artifact is gated
  with the ROM excluded (it is swept in the default run); neither has been re-run.

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
`s` (identity 2); otherwise `m` equals the exact max recurrence
`m == ($past(s) >= $past(m)) ? $past(s) : $past(m)` (the Phase 3 exact-max property,
which strictly subsumes the retained monotonicity assert [EVIDENCE: phase3-closure]).
Task p1 proves the same for the PIPE_ROM = 1 elaboration plus the latency-2 port
alignment [EVIDENCE: audit-online_softmax-pipe-formal-coverage]. NOT proven:
ROM contents, the 40-bit multiply's numerical correctness, or the DEN no-overflow
induction bound; those are cocotb's job (`rom_full_sweep`, `full_row_golden_compare`,
and the DEN assert inside `softmax_step()`) [EVIDENCE: verify-online_softmax],
[EVIDENCE: audit-online_softmax-formal-coverage].

**attention_top** (formal/attention_top.sby, smtbmc yices; z3 hangs on this
memory-heavy model): the property list is control-only, per the .sby header comment
and docs/uarch.md 8.3's own "FORMAL block" paragraph: reset state (`S_IDLE`,
`busy=0`, `done=0`, `cycle_count=0`), busy/done mutual exclusion, done implies idle,
`cycle_count` monotone non-decreasing while busy, and (2026-09-18) lane_out_valid
one-hot-or-zero. The verified revision ran at BMC depth 10 from an assumed reset
[EVIDENCE: audit-attention_top-formal-coverage]. Correction (2026-09-18, review
finding F013): the shortest run is 173 cycles, so at depth 10 `done` can never be 1
and the done-based properties were proven vacuously; the .sby now runs a `prove`
task at depth 180 with `n_len` assumed 4 on the accepted start, and a `cover` task
that must reach `cover (done)`. Neither task has been run yet.

### 5.3 The chformal reductions, and their justification chain

| .sby file | Strips assertions from | Justification |
|-----------|--------------------------|----------------|
| formal/matmul_tile.sby | `mac_unit` | The 16 mac_unit instances are wired identically by the same generate body; the contract is already proven standalone at depth 20 (formal/mac_unit.sby, PASS, auditor-countersigned). Re-proving 16 replicated copies of an identical contract inside the tile-level BMC is redundant solver load for zero additional coverage. |
| formal/attention_top.sby | `mac_unit`, `matmul_tile`, `online_softmax` | All three submodules are instantiated in attention_top UNMODIFIED (docs/uarch.md 8.3's own words); each contract is already proven standalone and auditor-countersigned (formal/mac_unit.sby, formal/matmul_tile.sby, formal/online_softmax.sby, all PASS). Re-proving them again inside the integration-level BMC would be redundant for zero additional coverage, and the full unstripped netlist (3 RAMs, a ROM, 16+16 multipliers, a 16-wide divider bank, plus the three submodules' own BMC-heavy assertions) is stated in the .sby header to be "far past what open smtbmc/z3 proves in a reasonable budget." |

Both reductions were independently audited: the formal-coverage auditor re-ran the
proofs, inspected the generated SMT2, and countersigned them as justified
[EVIDENCE: audit-matmul_tile-formal-coverage],
[EVIDENCE: audit-attention_top-formal-coverage]; for attention_top the
"non-vacuous" verdict holds for the reset, exclusion and monotonicity properties but
not for the done-based ones at the depth then used (see 5.2 and the EVIDENCE errata).

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
- The exact-max property for `m` is DONE (Phase 3, [EVIDENCE: phase3-closure]). Still
  planned: machine-checked induction for the width bounds. Today the three
  width/overflow bounds that matter most (mac_unit's SACC bound at D <= 511, docs/uarch.md 3.2; the DEN
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

Applied to the modules built so far: all four have cleared steps 1 to 3
[EVIDENCE: verify-mac_unit], [EVIDENCE: audit-mac_unit-lint-synth],
[EVIDENCE: audit-mac_unit-formal-coverage], [EVIDENCE: verify-matmul_tile],
[EVIDENCE: audit-matmul_tile-lint-synth], [EVIDENCE: audit-matmul_tile-formal-coverage],
[EVIDENCE: verify-online_softmax], [EVIDENCE: audit-online_softmax-lint-synth],
[EVIDENCE: audit-online_softmax-formal-coverage], [EVIDENCE: verify-attention_top],
[EVIDENCE: audit-attention_top-lint-synth],
[EVIDENCE: audit-attention_top-formal-coverage]; none has cleared step 4. Caveat for
every verify row appended before the 2026-07-16 .PHONY fix: `make formal` was
silently skipped by make at the time, so those rows' "formal" clause rests on the
auditors' direct sby runs, not on the verify target (EVIDENCE errata).

### 6.1 attention_top: what was checked, and what re-verification is owed

The planned checks below all landed and passed for the revision recorded in
[EVIDENCE: verify-attention_top] and [EVIDENCE: audit-attention_top-formal-coverage]
(6/6 tests on two seeds, bit-exact end to end):

- End-to-end golden compare across n in {4, 8, 16, 32, 64} with cycle-formula
  equality (test `end_to_end_golden`); corners (`corners`); mid-run reset
  (`rst_mid_run`); back-to-back runs without reset (`multi_run_no_reset`); random
  regression; write-port/read-port contracts (`write_port_readback`).
- Control-only formal with the three-way chformal reduction of 5.2/5.3.

Owed after the 2026-09-18 review (PLAN.md row back to [Building] until done):

- Re-run `make verify MODULE=attention_top` on the shared-PV RTL (docs/uarch.md 8.3
  implementation note) on two seeds, which also exercises the four added tests
  (`nonpow2_group_counts`, `start_while_busy_ignored`, `sel3_write_ignored`,
  `test_zz_coverage_closure`) and the new functional coverage gate.
- Run the depth-180 `prove` and `cover` formal tasks and record the achieved depth
  and runtime.
- Re-synthesize and confirm the multiplier count dropped to the 48 the spec states.
- Append the resulting rows with unique ids and re-run the dual auditor countersign.

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
