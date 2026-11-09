# Design rules

The engineering rules this repo is held to. docs/uarch.md is the spec;
this file is how the RTL, tests and claims are kept accurate.

## RTL coding standard
- Synthesizable only: every always_comb assigns all outputs on all paths
  or has a default (no inferred latches); every sequential element is
  reset; no initial blocks in RTL (formal-only blocks under `ifdef FORMAL`
  are the one exemption).
- Fixed point: every datapath block documents its Q-format, accumulator
  width, rounding and saturation. If the code and docs/uarch.md disagree,
  one of them is a bug and gets fixed.
- Lint (verilator -Wall, verible) and a latch-free yosys check are gates,
  not suggestions.

## Verification
- The golden model (model/attn.py, model/attn.cpp) is bit-accurate to the
  hardware: same Q-formats, the same exp LUT, same rounding and saturation.
  It was finished before any datapath RTL.
- Formal is a subset: small, yosys-parseable properties (control,
  alignment, clamp facts). Rich value checking lives in cocotb against the
  golden model. A BMC depth that cannot reach a property's trigger proves
  nothing (attention_top's shortest run is 173 cycles, so its proof runs
  to depth 180 with a cover task showing `done` is reachable).
- Fixed point is where errors hide: every width, rounding and saturation
  bound is derived, not assumed from small tests.
- Gates must be able to fail: recipes that pipe a tool into tee use
  pipefail, the coverage gate counts what it says it counts, and each gate
  was tested negatively.

## Definition of done (per module)
`make verify MODULE=<m>` exits 0: lint, cocotb vs the golden model,
coverage gate, latch-free synth check and the SymbiYosys proof. The run
appends a timestamped row to EVIDENCE.md. A change to the RTL, the tests
or a gate puts the module back to "needs re-run" until verify is green
again.

## Claims: simulation vs hardware
Simulation, coverage, lint, synthesis, formal, STA, GLS and tool power
estimates can be stated as results. Anything that needs a board or silicon
(measured Fmax, bench power, "runs on the FPGA", "taped out") is not
claimed until there is bench evidence for it in EVIDENCE.md.
`make audit-guide` checks the claim documents mechanically.
