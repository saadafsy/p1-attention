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

Review note (2026-09-18): a two-reviewer static audit found no datapath bug
but several gate, proof and documentation defects; all are fixed on branch
review-fixes and recorded as errata rows at the end of EVIDENCE.md. Three
fixes touch verified code (attention_top's PV datapath restructured into the
one shared bank the spec always described; attention_top formal now proves
completion at depth 180 instead of vacuously at depth 10; the UART wrapper
NAKs out-of-contract SET_NLEN and reads-while-busy) and several tighten
gates (line coverage counts only line points, with declared waivers; synth
and STA recipes fail when the tool fails). None of those changes has been
re-run through the toolchain yet: PLAN.md marks the affected modules
[Building] and the table below describes the last verified revision.

| Item | Status | Evidence |
|------|--------|----------|
| Phase -1: toolchain smoke test through the full verify pipeline | PASS | [verify-tool_smoke] |
| Phase 0: golden models (Python, C++) bit-identical, LUT emitted, float error gate met | PASS | [model-crosscheck] |
| rtl/mac_unit.sv: verify green, dual auditor countersigned (TB seed plumbing fixed 2026-09-18, re-verify pending) | PASS, re-verify | [verify-mac_unit], [audit-mac_unit-lint-synth], [audit-mac_unit-formal-coverage], [errata-mac_unit-two-seeds-20260918] |
| rtl/matmul_tile.sv: verify green, dual auditor countersigned | PASS | [verify-matmul_tile], [audit-matmul_tile-lint-synth], [audit-matmul_tile-formal-coverage] |
| rtl/online_softmax.sv: verify green, dual countersigned, re-audited after PIPE_ROM parameterization | PASS | [verify-online_softmax], [audit-online_softmax-pipe-lint-synth], [audit-online_softmax-pipe-formal-coverage] |
| rtl/attention_top.sv: end-to-end integration, BRAM-pattern memories, dual countersigned (last verified revision; shared-PV rewrite + depth-180 formal 2026-09-18, re-verify pending) | PASS, re-verify | [verify-attention_top], [bram-conversion-attention_top], [audit-attention_top-lint-synth], [audit-attention_top-formal-coverage], [errata-pv-datapath-structure-20260918], [errata-attention_top-formal-vacuous-20260918] |
| Phase 2 benchmark vs the CPU golden model (cycle counts, closed-form model; MAC count corrected 2026-09-18) | closed | docs/benchmark.md, tb/attention_top/cycles.txt, [errata-benchmark-mac-count-20260918] |
| Phase 3: functional coverage 52/52 reachable bins + exact-max formal property | closed | [phase3-closure] |
| Phase 4: PIPE_ROM pipelining iteration, sky130 STA, GLS both netlists 0 errors | closed | [phase4-sta] |
| Phase 5: switching-activity power proxy + tradeoffs writeup | closed | [phase5-docs] |
| Phase 6 bring-up kit (fpga/, host script): verified in simulation only (protocol hardened 2026-09-18, re-verify pending) | sim PASS, re-verify | [fpga-kit-sim], [audit-fpga-kit-lint-synth], [audit-fpga-kit-formal-coverage] |
| Phase 6 on a board, Phase 7 silicon | PENDING-HARDWARE; Phase 7 GDS is future sandbox work | see docs/ |

Bracketed ids are rows in [EVIDENCE.md](EVIDENCE.md), the append-only ledger
every `make verify` and `make model-check` run writes to on success (rows
carry a UTC timestamp suffix since 2026-09-18 so a citation names one run).
Per PLAN.md, closed phases are [Ready], not [Done]: the Done gate
additionally requires the project owner's Mode-B replication pass, which
has not run yet. Numbers quoted from build/ reports (slack, cells, toggles,
mW) are inspectable from a clone only once `make evidence-snapshot` has
copied the reports into evidence/ (evidence/README.md); no snapshot exists
yet for the historical rows.

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
checked mechanically by `make audit-guide` (scripts/audit_claims.py): a
sentence-level scan of guide.md, this README and the docs/ writeups that
fails the build on a hardware/silicon verb without an interim qualifier in
the same clause. It is a heuristic gate, not a proof of honesty; the ledger
is. The "timing limiter" statement above is an inference from block-level
STA of online_softmax, mac_unit and matmul_tile; no attention_top netlist
has been through STA.

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
scripts/  check_coverage.py (the coverage gate: line points + declared
          waivers, functional TOTAL), audit_claims.py (claim audit),
          evidence_snapshot.py, sta.tcl and power_proxy.tcl (OpenSTA),
          gen_gls_vectors.py (spec-derived GLS vectors), toggle_count.py
          (VCD activity), benchmark_cpu.py.
evidence/ Tracked snapshots of the build/ reports EVIDENCE rows cite.
build/    Generated netlists, synthesis/STA/GLS/power logs (gitignored).
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

# Phase 4: sky130 netlists + OpenSTA (needs LIB, see below), then
# gate-level sim of both configs (`make gls` builds both netlists first)
make synth-netlist MODULE=online_softmax
make sta MODULE=online_softmax PERIOD_NS=26
make synth-netlist-pipe1
make sta-pipe1 PERIOD_NS=13
make gls

# Phase 5: switching-activity comparison of the two GLS VCDs
python3 scripts/toggle_count.py build/gls_lat1.vcd build/gls_lat2.vcd

# Audit the claim documents for unbacked hardware claims; snapshot reports
make audit-guide
make evidence-snapshot
```

Toolchain paths. Two locations are machine-specific and must be set (or
staged at the default) before the Phase 4 targets run: `LIB`, the sky130
liberty file (`make ... LIB=/path/to/sky130_fd_sc_hd__tt_025C_1v80.lib`,
default `$HOME/tools/lib/`), and `CELLS_SRC` in tb/gls/Makefile, the
directory holding the PDK's `sky130_fd_sc_hd.v` and `primitives.v` (default
the oss-cad-suite eqy example). The Phase 4 targets fail with a message if
`LIB` is missing. Everything before Phase 4 needs only verilator, verible,
cocotb, yosys and sby on PATH. Line endings are pinned to LF by
.gitattributes; a checkout with `core.autocrlf=true` before 2026-09-18
broke the LUT checksum check.

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
