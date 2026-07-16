# ASIC guide.md fidelity rubric

The measurable version of "same level of detail as the STM32 guide." The writer is
graded against this per section; the verifier can run it too. Each row is a depth
feature from the reference guide, its ASIC translation, and a pass test. Aim: every
box checkable, so "deep enough" stops being a judgment call.

## Global (whole document)
- [ ] Build-ordered: sections follow the actual build sequence (spec -> uarch ->
      RTL -> testbench -> coverage -> lint -> synth -> formal), not a topic dump.
- [ ] Stop and Verify gate at the end of each build phase, each tied to a make
      target and a Pass criterion. (Reference guide has these per phase.)
- [ ] Glossary defines every load-bearing term the first time it is used. Test:
      pick 10 technical terms at random; each has a first-use definition.
- [ ] Every code block is pasted verbatim from a repo file and labeled with its path.
      Test: diff any block against the file; must match.
- [ ] Every number traces to a derivation shown inline or a named report. Test: pick
      5 numbers; each has a shown computation or a report citation.
- [ ] No claim without an EVIDENCE.md row. Test: `make audit-guide` exits 0.
- [ ] No em dashes. Test: grep for the character; zero hits.

## Per-module RTL walkthrough (mirrors "every register write explained")
- [ ] Every always_ff and always_comb block has a plain-English explanation of what
      it does and why, adjacent to the pasted code.
- [ ] Every module parameter is justified (why this width, why this depth).
- [ ] Every reset is accounted for; the guide states the reset style and shows it.
- [ ] Blocking vs non-blocking usage is explained where it matters.
- [ ] At least one "common mistake" box per module, naming the real footgun for that
      construct (for example: multi-bit binary pointer across a clock domain).

## Worked derivations (mirrors PLL/BRR/CCR math)
The guide must contain, for the design's actual features, derivations of this kind,
shown step by step, not asserted:
- [ ] Any sizing decision derived (FIFO depth, pipeline latency, counter width).
- [ ] Any CDC element derived (gray-code pointer width, synchronizer stage count and
      the MTBF reasoning behind it).
- [ ] Fmax and slack read from the STA/timing report, with the critical path named.
- [ ] Resource numbers (cells/LUTs/FFs) read from `yosys stat` or the P&R report.

## Deep concept dives (mirrors "the dives you'll get grilled on")
One dive per concept the design exercises, each explaining the physics/mechanism, not
just the API:
- [ ] Metastability and synchronizer MTBF (if any CDC).
- [ ] Clock domain crossing strategy (if multi-clock).
- [ ] Reset synchronization (async assert, sync deassert) and why.
- [ ] FSM encoding tradeoffs (binary vs one-hot) for the control logic.
- [ ] Setup/hold, slack, and how timing closure is reached.
- [ ] Formal vs simulation: what each proves and their limits.

## Silicon / timing appendix (mirrors the register/silicon appendix)
- [ ] The slack equation and what a negative number means physically.
- [ ] Standard-cell timing arcs / propagation delay, at a level a reader can defend.
- [ ] Why an inferred latch destroys timing closure and how synth reports it.
- [ ] Metastability at the flop level (the settling-time story).

## Verification section (mirrors the test matrix + evidence discipline)
- [ ] Coverage model: every functional bin named, with why it matters.
- [ ] Every SVA property stated in English, then in code, then its proof status.
- [ ] Test matrix: one row per check (lint, sim, coverage, synth-check, formal),
      each with a Pass criterion and an Evidence cell (command + artifact written).
- [ ] Counterexample handling: how a failing assertion's CEX trace is read.

## Honesty / stage-gating (mirrors the honest-status page)
- [ ] A clear status paragraph stating what is proven in sandbox vs what needs
      hardware/silicon.
- [ ] Resume bullets only stage-gated, with a clause-to-evidence table.
- [ ] Every hardware/silicon verb (runs on FPGA, taped out, measured, on the board)
      is either backed by a user-supplied evidence row or written in interim voice.

## Extras that make the reference guide feel complete
- [ ] Architecture block diagram and at least one FSM or datapath diagram (Mermaid).
- [ ] One waveform walkthrough of a representative transaction.
- [ ] Debugging guide organized by symptom, each with the instrument that finds it.
- [ ] Interview Q&A in first person, one per deep concept.
- [ ] Advanced extensions, ordered easiest to hardest.

## Scoring
A section passes only if every applicable box is checked. "Applicable" is decided by
what the design actually contains: a single-clock design skips the CDC and MTBF
boxes but must then have no CDC claims anywhere. The rubric scales to the design; it
does not let a shallow section through.

## P1 applicability note (single-clock attention engine)
This design is (initially) single-clock. Per the scaling rule:
- CDC / metastability / MTBF boxes are NON-APPLICABLE and there must be ZERO CDC or
  metastability claims anywhere in the guide. Do not import async-FIFO prose.
- Worked-derivation boxes retarget to: fixed-point Q-format + error bound, accumulator
  width, pipeline latency, Fmax/slack from STA, cell counts from yosys stat.
- Deep-concept dives retarget to: online-softmax numerical stability, fixed-point
  quantization, systolic/weight-stationary dataflow, pipelining/retiming, FSM encoding
  for the tile controller, formal-vs-simulation.
If a second clock domain is later added at the memory interface, the CDC/MTBF boxes
re-apply and must then be satisfied.
