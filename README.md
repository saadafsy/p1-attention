# p1-attention: a fixed-point streaming attention engine in SystemVerilog

Tiled Q.K^T matmul (TPU-paper lineage) feeding an online softmax
(FlashAttention-paper lineage), verified against a bit-exact dual golden model
(Python and C++), with cocotb simulation, functional and line coverage, lint,
latch-free synthesis checks, and bounded formal proofs.

## Status

Every result below cites an EVIDENCE.md row id. No claim in this table is made
without one.

| Item | Status | Evidence |
|------|--------|----------|
| Phase -1: toolchain smoke test through the full verify pipeline | PASS | [verify-tool_smoke] |
| Phase 0: golden models (Python, C++) bit-identical, LUT emitted, float error gate met | PASS | [model-crosscheck] |
| rtl/mac_unit.sv: verify green, dual auditor countersigned | PASS | [verify-mac_unit], [audit-mac_unit-lint-synth], [audit-mac_unit-formal-coverage] |
| rtl/matmul_tile.sv: verify green, dual auditor countersigned | PASS | [verify-matmul_tile], [audit-matmul_tile-lint-synth], [audit-matmul_tile-formal-coverage] |
| rtl/online_softmax.sv: verify green, dual auditor countersigned | PASS | [verify-online_softmax], [audit-online_softmax-lint-synth], [audit-online_softmax-formal-coverage] |
| rtl/attention_top.sv: end-to-end integration | IN PROGRESS, not yet verified, no result claimed | no row yet |
| Phase 4 (synthesis timing/STA), Phase 6 (FPGA), Phase 7 (GDS/silicon) | future work / PENDING-HARDWARE, see below | see docs/ |

Bracketed ids are rows in [EVIDENCE.md](EVIDENCE.md), the append-only ledger every
`make verify` and `make model-check` run writes to on success.

## The sandbox/silicon wall

RTL correctness, simulation, functional and line coverage, lint, synthesis to a
gate-level netlist, and bounded formal proof are sandbox-provable and are stated
plainly above once their EVIDENCE.md row exists. The three completed modules
(mac_unit, matmul_tile, online_softmax) are verified in simulation and formal;
each is synthesized to a latch-free netlist (yosys check, 0 problems). No static
timing report exists yet (STA is Phase 4, not yet run), so no Fmax number is
claimed anywhere in this repo's documentation. Nothing in this project is
implemented on FPGA, and nothing is fabricated: both stay PENDING-HARDWARE until
real bench evidence (a board bring-up log, a measured clock sweep, a chip photo)
is added as an EVIDENCE.md row. This wall is enforced mechanically for guide.md
by `make audit-guide`, which fails the build if an unbacked hardware/silicon claim
appears in it.

## Repo map

```
rtl/      SystemVerilog design: mac_unit, matmul_tile, online_softmax,
          attention_top (in progress), the generated exp_lut.svh ROM.
tb/       cocotb testbenches, one directory per module, each with its own
          coverage.dat / results.xml.
model/    The bit-exact dual golden model: attn.py (normative, NumPy/pure
          integer), attn.cpp (independent reimplementation), crosscheck.py
          (the prover), exp_lut.hex (the normative LUT interchange file).
formal/   SymbiYosys (.sby) bounded-model-check setups, one per module.
docs/     uarch.md (the normative numeric/microarchitecture spec),
          verification_plan.md (this project's Phase 5 plan), the Phase 6
          FPGA and Phase 7 physical-design beginner guides.
scripts/  check_coverage.py (the coverage gate), sta.tcl, benchmark_cpu.py.
```

## Reproduce it yourself

All commands run from the repo root. The `verify` and `model-check` Makefile
targets append their own EVIDENCE.md rows on success.

```
# Phase -1: prove the toolchain before trusting any RTL result
make verify MODULE=tool_smoke COVERAGE_STUB=1

# Phase 0: golden models bit-identical + float error gate (14 cases)
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

# Audit guide.md for unbacked hardware claims
make audit-guide
```

## Further reading

- [guide.md](guide.md): the full build-ordered technical guide (toolchain,
  numeric contract, golden models, and a per-module RTL/verification
  walkthrough for every completed module).
- [docs/uarch.md](docs/uarch.md): the normative source of truth for every
  number format, width derivation, rounding site, and saturation site. If code
  and this file disagree, the code is the bug.
- [docs/verification_plan.md](docs/verification_plan.md): the Phase 5
  verification plan (features under verification, stimulus strategy, coverage
  goals, formal strategy, sign-off criteria).
- [EVIDENCE.md](EVIDENCE.md): the claim ledger. Every result in this README and
  in guide.md traces back to a row here.
- [docs/phase6_fpga_guide.md](docs/phase6_fpga_guide.md): the Basys 3 FPGA
  bring-up plan. States plainly that nothing in it has been executed yet.
- [docs/phase7_physical_guide.md](docs/phase7_physical_guide.md): the
  OpenLane/Sky130 RTL-to-GDS plan and the TinyTapeout silicon path. GDS and
  power estimates are sandbox-achievable; fabricated silicon is
  PENDING-HARDWARE plus money.
