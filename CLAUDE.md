# CLAUDE.md — Project 1: Streaming Attention Engine (builder mode)

## What this project is
A fixed-point streaming attention accelerator (online softmax + tiled matmul) in
SystemVerilog, verified with cocotb + functional coverage + SVA, synthesized and
timing-checked (Yosys/OpenSTA), taken through the open RTL-to-GDS flow (OpenLane/
Sky130), optionally FPGA-demonstrated and taped out via TinyTapeout. Reference theory:
the Google TPU paper (tiled/weight-stationary matmul) and the FlashAttention paper
(online softmax). Build order and phase gates: P1_Attention_Engine_Build_Sheet.md.

## Mode of operation
The agents BUILD the result. rtl-designer and verification-engineer implement the
modules; the read-only auditors re-run and countersign; the technical-writer documents
the finished result into guide.md.

AFTER the build is green, the technical-writer switches to MODE B (replication tutor):
it makes ME rebuild each module from a blank file, revealing nothing verbatim, grilling
me until I can defend every line. Mode B is gated: it refuses to run on any module that
does not yet have a VERIFY OK row in EVIDENCE.md.

## Build order (one module at a time, verify green before the next)
mac_unit -> matmul_tile -> online_softmax -> attention_top, then phases 3-7 of the
build sheet.

## RTL coding standard (enforced by lint hook + auditors)
- Synthesizable only: every always_comb assigns all outputs on all paths or has a
  default (no inferred latches); reset every sequential element; no initial blocks in RTL.
- Fixed-point: document Q-format, accumulator width, rounding, saturation per datapath
  block. docs/uarch.md is the source of truth for naming and microarchitecture.

## Definition of Done (per module)
make verify exits 0 (lint + sim vs golden + coverage + synth-check + formal where
applicable), an EVIDENCE.md PASS row exists, and a Beta auditor countersigned. My own
Mode-B replication happens after, as the learning pass.

## The sandbox/silicon wall (honesty, non-negotiable)
RTL correctness, coverage, lint, synth-to-netlist, and formal are sandbox-provable and
may be stated. Anything needing a real FPGA board or silicon (measured Fmax on hardware,
bench power, "runs on the board", "taped out") stays PENDING-HARDWARE until I supply
evidence. Interim voice: "verified in simulation and formal; synthesized to a latch-free
netlist meeting timing at <Fmax from report> in <tool>; not implemented on FPGA / not
taped out."

## Resume bullets only stage-gated, with clause-to-evidence. No em dashes in docs.

## Pre-empted struggles (read before building)
1. TOOLCHAIN FIRST. Before any P1 module, complete Phase -1 (tool_smoke): a throwaway
   counter taken through the whole verify pipeline. Do not touch mac_unit until
   `make verify MODULE=tool_smoke COVERAGE_STUB=1` exits 0. Half-installed tools cause
   failures that look like RTL bugs and waste the session.
2. OPENLANE IS PHASE 7 ONLY. Do not install or run OpenLane/Sky130 during Phases 0-5;
   its Docker stack is heavy and must not block core work. iverilog/verilator/yosys/sby
   are enough for Phases 0-5.
3. BIT-ACCURATE GOLDEN MODEL is the #1 P1 risk. model/ must match the hardware exactly
   (same Q-format, same exp LUT emitted for the RTL, same rounding/saturation) BEFORE any
   datapath RTL. Float-exp models never match fixed-point RTL.
4. FORMAL IS A SUBSET. Open-source sby proves only simple SVA. Keep properties minimal
   and yosys-parseable; push rich checking into cocotb. Do not fight the tool.
5. FIXED-POINT IS WHERE ERRORS HIDE. For every width/rounding/saturation choice, SHOW the
   arithmetic derivation (the rubric requires it). Passing a small test does not prove no
   overflow; small tests miss it. These derivations are the human review point.
6. ONE MODULE PER SESSION. Commit to git after each green module. Start a fresh session
   per phase; PLAN.md and EVIDENCE.md are the persistent memory. Read them at session start.
7. HOOKS ARE DEV-FRIENDLY. lint-on-edit only hard-blocks files listed in .ready_for_lint;
   add a module's path there when you declare it ready. Never mark [Done] before verify passes.
