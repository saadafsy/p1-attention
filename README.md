# p1-attention: a fixed-point streaming attention engine in SystemVerilog

Tiled Q.K^T matmul (TPU-paper lineage) feeding an online softmax
(FlashAttention-paper lineage), integrated end to end behind BRAM-inferable
memories, verified against a bit-exact dual golden model (Python and C++),
with cocotb simulation, functional and line coverage, lint, latch-free
synthesis checks, bounded formal proofs, sky130 synthesis with OpenSTA
timing, gate-level simulation of the netlists, and a switching-activity
power proxy.

## Status

Every result below cites an EVIDENCE.md row id. No claim in this table is
made without one.

| Item | Status | Evidence |
|------|--------|----------|
| Phase -1: toolchain smoke test through the full verify pipeline | PASS | [verify-tool_smoke] |
| Phase 0: golden models (Python, C++) bit-identical, LUT emitted, float error gate met | PASS | [model-crosscheck] |
| rtl/mac_unit.sv: verify green, dual auditor countersigned | PASS | [verify-mac_unit], [audit-mac_unit-lint-synth], [audit-mac_unit-formal-coverage] |
| rtl/matmul_tile.sv: verify green, dual auditor countersigned | PASS | [verify-matmul_tile], [audit-matmul_tile-lint-synth], [audit-matmul_tile-formal-coverage] |
| rtl/online_softmax.sv: verify green, dual countersigned, re-audited after PIPE_ROM parameterization | PASS | [verify-online_softmax], [audit-online_softmax-pipe-lint-synth], [audit-online_softmax-pipe-formal-coverage] |
| rtl/attention_top.sv: end-to-end integration, BRAM-pattern memories, dual countersigned | PASS | [verify-attention_top], [bram-conversion-attention_top], [audit-attention_top-lint-synth], [audit-attention_top-formal-coverage] |
| Phase 2 benchmark vs the CPU golden model (cycle counts, closed-form model) | closed | docs/benchmark.md, tb/attention_top/cycles.txt |
| Phase 3: functional coverage 52/52 reachable bins + exact-max formal property | closed | [phase3-closure] |
| Phase 4: PIPE_ROM pipelining iteration, sky130 STA, GLS both netlists 0 errors | closed | [phase4-sta] |
| Phase 5: switching-activity power proxy + tradeoffs writeup | closed | [phase5-docs] |
| Phase 6 (FPGA), Phase 7 silicon | PENDING-HARDWARE; Phase 7 GDS is future sandbox work | see docs/ |

Bracketed ids are rows in [EVIDENCE.md](EVIDENCE.md), the append-only ledger
every `make verify` and `make model-check` run writes to on success. Per
PLAN.md, closed phases are [Ready], not [Done]: the Done gate additionally
requires the project owner's Mode-B replication pass, which has not run yet.

## The sandbox/silicon wall

RTL correctness, simulation, coverage, lint, synthesis to a gate-level
netlist, bounded formal proof, static timing analysis, gate-level
simulation, and tool-estimated power are sandbox-provable and are stated
plainly above once their EVIDENCE.md row exists. The honest one-line status:
the design is verified in simulation and formal and synthesized to
latch-free netlists; the online_softmax core, the design's timing limiter,
meets timing at 38.5 MHz naive and 76.9 MHz pipelined in OpenSTA at the
sky130 tt corner (tool estimates in simulation; neither configuration meets
the 10 ns target period, while mac_unit and matmul_tile do); nothing is
implemented on FPGA and nothing is fabricated. Every timing and power number
in this repo is a tool estimate at one corner; hardware claims stay
PENDING-HARDWARE until real bench evidence (a board bring-up log, a measured
clock sweep, a chip photo) is added as an EVIDENCE.md row. This wall is
enforced mechanically for guide.md by `make audit-guide`, which fails the
build if an unbacked hardware/silicon claim appears in it.

## Repo map

```
rtl/      SystemVerilog design: mac_unit, matmul_tile, online_softmax
          (PIPE_ROM parameterized), attention_top, the generated
          exp_lut.svh ROM.
tb/       cocotb testbenches, one directory per module, plus tb/gls (the
          gate-level simulation of the sky130 netlists).
model/    The bit-exact dual golden model: attn.py (normative), attn.cpp
          (independent reimplementation), crosscheck.py (the prover),
          exp_lut.hex (the normative LUT interchange file).
formal/   SymbiYosys (.sby) bounded-model-check setups, one per module
          (online_softmax runs two tasks, one per PIPE_ROM elaboration).
docs/     uarch.md (the normative numeric/microarchitecture spec),
          benchmark.md (Phase 2), verification_plan.md (Phase 5 plan),
          tradeoffs.md (Phase 5 naive-vs-pipelined writeup), the Phase 6
          FPGA and Phase 7 physical-design guides.
scripts/  check_coverage.py (the coverage gate), sta.tcl and
          power_proxy.tcl (OpenSTA), gen_gls_vectors.py (spec-derived GLS
          vectors), toggle_count.py (VCD activity), benchmark_cpu.py.
build/    Generated netlists, synthesis/STA/GLS/power logs.
```

## Reproduce it yourself

All commands run from the repo root. The `verify` and `model-check` targets
append their own EVIDENCE.md rows on success.

```
# Phase -1 toolchain gate, then Phase 0 golden models
make verify MODULE=tool_smoke COVERAGE_STUB=1
make model-check

# Per-module full gates (lint, sim, coverage, synth-check, formal)
make verify MODULE=mac_unit
make verify MODULE=matmul_tile
make verify MODULE=online_softmax
make verify MODULE=attention_top

# Phase 4: sky130 netlist + OpenSTA, and gate-level sim of both configs
make synth-netlist MODULE=online_softmax
make sta MODULE=online_softmax PERIOD_NS=26
make -C tb/gls all

# Phase 5: switching-activity comparison of the two GLS VCDs
python3 scripts/toggle_count.py build/gls_lat1.vcd build/gls_lat2.vcd

# Audit guide.md for unbacked hardware claims
make audit-guide
```

The full command set, including the PIPE_ROM=1 simulation, the pipelined
netlist synthesis, and the calibrated power proxy, is in
[guide.md](guide.md) section 12.

## Further reading

- [guide.md](guide.md): the full build-ordered technical guide (toolchain,
  numeric contract, golden models, per-module RTL/verification walkthroughs,
  the attention_top integration, Phase 3 coverage closure, Phase 4
  timing/GLS, Phase 5 power proxy, stage-gated resume bullets).
- [docs/uarch.md](docs/uarch.md): the normative source of truth for every
  number format, width derivation, rounding site, and saturation site. If
  code and this file disagree, the code is the bug.
- [docs/benchmark.md](docs/benchmark.md): attention_top cycle counts vs the
  CPU golden model, with the clock disclaimer.
- [docs/tradeoffs.md](docs/tradeoffs.md): naive vs pipelined online_softmax
  (timing, area, activity, calibrated power proxy, documented biases).
- [docs/verification_plan.md](docs/verification_plan.md): the Phase 5
  verification plan (features under verification, stimulus strategy,
  coverage goals, formal strategy, sign-off criteria).
- [EVIDENCE.md](EVIDENCE.md): the claim ledger. Every result in this README
  and in guide.md traces back to a row here.
- [docs/phase6_fpga_guide.md](docs/phase6_fpga_guide.md): the Basys 3 FPGA
  bring-up plan. States plainly that nothing in it has been executed yet.
- [docs/phase7_physical_guide.md](docs/phase7_physical_guide.md): the
  OpenLane/Sky130 RTL-to-GDS plan and the TinyTapeout silicon path. GDS and
  routed-parasitic power estimates are sandbox-achievable; fabricated
  silicon is PENDING-HARDWARE plus money.
