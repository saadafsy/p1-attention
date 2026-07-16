# PLAN — Project 1: Streaming Attention Engine

Task format:  [Status] <module>  (domain: sandbox|hardware)  owner: <who>
Status: [Todo] [Building] [Ready] [Done] [Blocked: needs bench]
Only Lead moves a task to [Done], and only after: make verify exits 0, an EVIDENCE row
exists, a Beta auditor countersigned, AND I passed "grill me". I write all rtl/ and formal/.

## Phase 0 — Golden models + fixed-point study
- [Todo] model/attn.py        (domain: sandbox)  owner: ME (agent may review)
- [Todo] model/attn.cpp       (domain: sandbox)  owner: ME (agent may review)

## Phase 1 — Core datapath RTL (I write; agent tutors + reviews)
- [Todo] rtl/mac_unit.sv           (domain: sandbox)  owner: ME
- [Todo] rtl/matmul_tile.sv        (domain: sandbox)  owner: ME
- [Todo] rtl/online_softmax.sv     (domain: sandbox)  owner: ME
- [Todo] tb/* self-checking vs golden model  (domain: sandbox)  owner: ME (agent may scaffold harness)

## Phase 2 — Integration + benchmark
- [Todo] rtl/attention_top.sv      (domain: sandbox)  owner: ME
- [Todo] benchmark vs CPU golden   (domain: sandbox)

## Phase 3 — Verification (cocotb + coverage + SVA)
- [Todo] tb/softmax coverage model + constrained-random  (domain: sandbox)  owner: ME
- [Todo] formal/online_softmax_props.sv                    (domain: sandbox)  owner: ME

## Phase 4 — Synthesis + STA
- [Todo] synth + OpenSTA report, one pipelining iteration  (domain: sandbox)

## Phase 5 — Verification plan + power proxy + tradeoffs writeup
- [Todo] docs/verification_plan.md                          (domain: sandbox)

## --- CORE COMPLETE ABOVE. Phases 6-7 do NOT start until 0-5 are Done. ---

## Phase 6 — FPGA (hardware, cannot reach Done in sandbox)
- [Blocked: needs bench] fpga_bringup   (domain: hardware)

## Phase 7 — Physical design + silicon
- [Todo] openlane RTL-to-GDS on the tile + KLayout screenshot  (domain: sandbox)
- [Todo] VCD switching-activity power estimate                 (domain: sandbox)
- [Blocked: needs bench] tinytapeout_silicon  (domain: hardware)
