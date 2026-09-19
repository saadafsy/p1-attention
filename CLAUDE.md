# CLAUDE.md: Project 1, Streaming Attention Engine (active rules)

This file holds the rules that are in force for anyone (human or agent)
working in this repo. The planning and process records that used to sit
beside it live under process/ (build sheet, conversion notes, the guide
fidelity rubric, the technical-writer contract); the design itself is
documented in docs/ (docs/uarch.md is the normative spec, docs/guide.md the
full walkthrough) and the claim ledger is EVIDENCE.md.

## What this project is
A fixed-point streaming attention accelerator (online softmax + tiled
matmul) in SystemVerilog, verified with cocotb + functional coverage + SVA,
synthesized and timing-checked (Yosys/OpenSTA), with an FPGA bring-up kit
and a physical-design path. Reference theory: the TPU paper (tiled matmul)
and the FlashAttention paper (online softmax). Build order and phase gates:
process/P1_Attention_Engine_Build_Sheet.md (with its superseded decisions
annotated).

## Mode of operation
Builder mode (process/CONVERSION_NOTES.md): rtl-designer and
verification-engineer implement; the read-only auditors re-run and
countersign; the technical-writer documents into docs/guide.md, then
switches to MODE B (replication tutor) only for modules with a VERIFY OK
row. Build order: mac_unit -> matmul_tile -> online_softmax ->
attention_top, one module at a time, verify green before the next.

## RTL coding standard (enforced by the lint hook + auditors)
- Synthesizable only: every always_comb assigns all outputs on all paths
  or has a default (no inferred latches); reset every sequential element;
  no initial blocks in RTL (formal-only blocks under `ifdef FORMAL are the
  documented exemption).
- Fixed-point: document Q-format, accumulator width, rounding and
  saturation per datapath block. docs/uarch.md is the source of truth; if
  code and that file disagree, the code is the bug.

## Definition of Done (per module)
`make verify MODULE=<m>` exits 0 (lint + sim vs golden + coverage +
synth-check + formal), a verify-<m>-<stamp> PASS row exists in EVIDENCE.md,
and a Beta auditor countersigned. Only then may PLAN.md say [Ready]; [Done]
additionally needs the owner's Mode-B replication pass. Never mark a row
past what its gate has actually run; a changed gate, RTL or test puts the
module back to [Building].

## The sandbox/silicon wall (non-negotiable)
RTL correctness, coverage, lint, synth-to-netlist, formal, STA, GLS and
tool power estimates are sandbox-provable and may be stated as such.
Anything needing a real board or silicon (measured Fmax, bench power,
"runs on the board", "taped out") stays PENDING-HARDWARE until bench
evidence is added as an EVIDENCE row. Interim voice: "verified in
simulation and formal; synthesized to a latch-free netlist meeting timing
at <Fmax from report> in <tool>; not implemented on FPGA / not taped out."
`make audit-guide` checks the claim documents mechanically.

## Resume bullets only stage-gated, with clause-to-evidence. No em dashes in docs.

## Pre-empted struggles (read before building)
1. TOOLCHAIN FIRST: `make verify MODULE=tool_smoke COVERAGE_STUB=1` must
   exit 0 before any P1 module is touched.
2. OPENLANE IS PHASE 7 ONLY; iverilog/verilator/yosys/sby are enough before.
3. BIT-ACCURATE GOLDEN MODEL is the #1 risk: model/ must match the hardware
   exactly (same Q-format, the SAME exp LUT, same rounding/saturation)
   before any datapath RTL.
4. FORMAL IS A SUBSET: minimal, yosys-parseable properties; rich checking
   in cocotb. A BMC depth that cannot reach the property's trigger proves
   nothing (attention_top: shortest run is 173 cycles).
5. FIXED-POINT IS WHERE ERRORS HIDE: show every width/rounding/saturation
   derivation; small tests do not prove no overflow.
6. ONE MODULE PER SESSION; commit after each green module; PLAN.md and
   EVIDENCE.md are the persistent memory.
7. HOOKS ARE DEV-FRIENDLY: lint-on-edit hard-blocks only files listed in
   .ready_for_lint (repo-relative paths); never mark [Done] before verify.
8. GATES MUST BE ABLE TO FAIL: a recipe that pipes a tool into tee needs
   pipefail; a coverage gate must count what it says it counts; a claim
   audit must look at the clause the verb is in. Test each gate negatively.
