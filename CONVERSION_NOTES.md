# P1 conversion — builder mode with a post-build replication tutor

## Decision recorded
Agents BUILD the full P1 result. After it is green, the technical-writer runs MODE B
(replication tutor) to make the user rebuild it from scratch and defend every line. The
user accepted the tradeoff: replicate from a BLANK file with the result hidden, not
side by side, or the defense stays the agent's and not theirs.

## Kept from the original scaffold (unchanged, project-agnostic, good)
- Evidence gating (EVIDENCE.md); no guide claim without a PASS row.
- Sandbox/silicon honesty wall + PENDING-HARDWARE + stage-gated resume bullets.
- Read-only red-team auditors (lint-synth, formal-coverage).
- Hooks: lint-on-edit, verify_gate Stop hook, audit-guide hardware-claim grep.
- The fidelity rubric and technical-writer contract.

## Changed for P1
1. Builders restored and retargeted:
   - rtl-designer BUILDS mac_unit -> matmul_tile -> online_softmax -> attention_top,
     grounded in the TPU + FlashAttention papers, fixed-point documented per block.
   - verification-engineer BUILDS cocotb TB + coverage + SVA, checks RTL vs
     model/attn.py and model/attn.cpp golden models.
2. technical-writer gains MODE B (replication tutor), GATED to post-verify:
   refuses to tutor any module without a VERIFY OK row; makes the user rebuild from a
   blank file; Socratic + grill; no Write/Edit in Mode B; reveals nothing verbatim.
3. Modules FIFO -> attention: async_fifo -> {mac_unit, matmul_tile, online_softmax,
   attention_top}. PLAN and Makefile default MODULE = mac_unit.
4. Rubric applicability (single-clock): CDC/metastability/MTBF boxes NON-APPLICABLE
   with zero CDC claims allowed; derivations retarget to fixed-point Q-format + error
   bound, accumulator width, pipeline latency, Fmax/slack, cell counts; dives retarget
   to online-softmax stability, fixed-point quantization, systolic dataflow, pipelining/
   retiming, FSM encoding, formal-vs-sim.
5. EVIDENCE rows: lint/sim/cov/synth/fmax/formal for softmax+tile; fpga-* and
   silicon-* PENDING-HARDWARE.

## The one discipline that makes this work
Mode B must be run from a BLANK file with guide.md/rtl closed. Side-by-side replication
is transcription and defeats the project. The gate (no Mode B without VERIFY OK) keeps
the writer from tutoring a half-built module, but only the user can keep the blank-file
rule. Make the grill brutal; a block is not "yours" until you pass it with nothing open.

## Run order
1. Put CLAUDE.md, technical-writer.md, asic-guide-fidelity-rubric.md,
   P1_Attention_Engine_Build_Sheet.md in the repo root.
2. bash setup-p1.sh
3. Fill docs/uarch.md (Q-format, tile size, pipeline depth) or let rtl-designer draft it.
4. claude ->  "Build Phase 0 then mac_unit per the build sheet. Stop after verify."
5. After green:  "tutor me on mac_unit"  (writer enters Mode B).
