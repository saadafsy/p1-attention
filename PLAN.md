# PLAN — Project 1: Streaming Attention Engine

Task format:  [Status] <module>  (domain: sandbox|hardware)  owner: <who>
Status: [Todo] [Building] [Ready] [Done] [Blocked: needs bench]
Only Lead moves a task to [Done], and only after: make verify exits 0, an EVIDENCE row
exists, a Beta auditor countersigned, AND I passed "grill me". I write all rtl/ and formal/.

## Phase 0 — Golden models + fixed-point study
- [Ready] model/attn.py        (domain: sandbox)  built per builder-mode decision; crosscheck green (make model-check, EVIDENCE row)
- [Ready] model/attn.cpp       (domain: sandbox)  built per builder-mode decision; bit-identical to attn.py on 14 cases

## Phase 1 — Core datapath RTL (I write; agent tutors + reviews)
- [Ready] rtl/mac_unit.sv          (domain: sandbox)  verify green (lint/sim/100% line cov/synth/formal), EVIDENCE row; awaits auditor countersign + grill
- [Ready] rtl/matmul_tile.sv       (domain: sandbox)  roster-built; verify green, both auditors countersigned; awaits grill
- [Ready] rtl/online_softmax.sv    (domain: sandbox)  roster-built; verify green, both auditors countersigned; awaits grill
- [Todo] tb/* self-checking vs golden model  (domain: sandbox)  owner: ME (agent may scaffold harness)

## Phase 2 — Integration + benchmark
- [Ready] rtl/attention_top.sv     (domain: sandbox)  roster-built; verify green incl. BRAM-pattern memories, both auditors countersigned; awaits grill
- [Ready] benchmark vs CPU golden  (domain: sandbox)  docs/benchmark.md + tb/attention_top/cycles.txt + build/cpu_baseline.txt

## Phase 3 — Verification (cocotb + coverage + SVA)
- [Todo] tb/softmax coverage model + constrained-random  (domain: sandbox)  owner: ME
- [Todo] formal/online_softmax_props.sv                    (domain: sandbox)  owner: ME

## Phase 4 — Synthesis + STA
- [Ready] synth + OpenSTA report, one pipelining iteration  (domain: sandbox)  PIPE_ROM registered-ROM variant of online_softmax (uarch 8.2.1, default 0 bit-identical); 38.5 -> 76.9 MHz sky130 tt for +9% area; dual re-audit + GLS both configs; phase4-sta EVIDENCE row; 10ns NOT met in either config (documented)

## Phase 5 — Verification plan + power proxy + tradeoffs writeup
- [Todo] docs/verification_plan.md                          (domain: sandbox)

## --- CORE COMPLETE ABOVE. Phases 6-7 do NOT start until 0-5 are Done. ---

## Phase 6 — FPGA (hardware, cannot reach Done in sandbox)
- [Blocked: needs bench] fpga_bringup   (domain: hardware)  Basys 3 / XC7A35T / Vivado; guide: docs/phase6_fpga_guide.md; PENDING-HARDWARE until bench evidence

## Phase 7 — Physical design + silicon
- [Todo] openlane RTL-to-GDS on the tile + KLayout screenshot  (domain: sandbox)  guide: docs/phase7_physical_guide.md
- [Todo] VCD switching-activity power estimate                 (domain: sandbox)  guide: docs/phase7_physical_guide.md section 7
- [Blocked: needs bench] tinytapeout_silicon  (domain: hardware)  ~$100 shuttle seat; guide: docs/phase7_physical_guide.md section 8; PENDING-HARDWARE
