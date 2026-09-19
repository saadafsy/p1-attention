# PLAN: Project 1: Streaming Attention Engine

Task format:  [Status] <module>  (domain: sandbox|hardware)  owner: <who>
Status: [Todo] [Building] [Ready] [Done] [Blocked: needs bench]
Only Lead moves a task to [Done], and only after: make verify exits 0, an EVIDENCE row
exists, a Beta auditor countersigned, AND I passed "grill me". Per process/CONVERSION_NOTES.md the
agents build rtl/ and formal/ in builder mode; my ownership is the Mode-B replication.

2026-09-18 review (EVIDENCE.md errata + review-fixes-20260918): the items marked
"re-verify" below changed code or gates after their last verify row and go back to
[Building] until `make verify` re-runs green and the auditors countersign again.

## Phase 0: Golden models + fixed-point study
- [Ready] model/attn.py        (domain: sandbox)  built per builder-mode decision; crosscheck green (make model-check, EVIDENCE row)
- [Ready] model/attn.cpp       (domain: sandbox)  built per builder-mode decision; bit-identical to attn.py on 14 cases

## Phase 1: Core datapath RTL (I write; agent tutors + reviews)
- [Building] rtl/mac_unit.sv       (domain: sandbox)  re-verify: TB seed plumbing fixed 2026-09-18 (was fixed-seed); last verify row verify-mac_unit
- [Ready] rtl/matmul_tile.sv       (domain: sandbox)  roster-built; verify green, both auditors countersigned; awaits grill
- [Building] rtl/online_softmax.sv (domain: sandbox)  re-verify: PIPE_ROM=1 coverage gate + observed pipe bins added 2026-09-18 (RTL unchanged); last verify row verify-online_softmax
- [Todo] tb/* self-checking vs golden model  (domain: sandbox)  owner: ME (agent may scaffold harness)

## Phase 2: Integration + benchmark
- [Building] rtl/attention_top.sv  (domain: sandbox)  re-verify: shared-PV datapath rewrite, depth-180 prove+cover formal, 4 new tests + functional coverage gate, line-coverage waivers (2026-09-18); last verified revision: verify-attention_top rows
- [Ready] benchmark vs CPU golden  (domain: sandbox)  docs/benchmark.md + tb/attention_top/cycles.txt + build/cpu_baseline.txt

## Phase 3: Verification (cocotb + coverage + SVA)
- [Todo] tb/softmax coverage model + constrained-random  (domain: sandbox)  owner: ME
- [Todo] formal/online_softmax_props.sv                    (domain: sandbox)  owner: ME

## Phase 4: Synthesis + STA
- [Ready] synth + OpenSTA report, one pipelining iteration  (domain: sandbox)  PIPE_ROM registered-ROM variant of online_softmax (uarch 8.2.1, default 0 bit-identical); 38.5 -> 76.9 MHz sky130 tt for +9% area; dual re-audit + GLS both configs; phase4-sta EVIDENCE row; 10ns NOT met in either config (documented)

## Phase 5: Verification plan + power proxy + tradeoffs writeup
- [Ready] docs/verification_plan.md                         (domain: sandbox)  refreshed 2026-09-18 to the ledger state (was stale on attention_top and the exact-max property)
- [Ready] power proxy + docs/tradeoffs.md                   (domain: sandbox)  VCD toggle counts + calibrated report_power, naive vs PIPE_ROM, identical GLS stimulus; phase5-docs EVIDENCE row

## --- CORE COMPLETE ABOVE. Phases 6-7 do NOT start until 0-5 are Done. ---

## Phase 6: FPGA (hardware, cannot reach Done in sandbox)
- [Building] fpga bring-up kit (fpga/ + host script + TBs)  (domain: sandbox)  re-verify: attn_uart_top now NAKs bad SET_NLEN and READ_OUT/READ_CYCLES while busy, sync2ff tags both flops, 2 new TB tests (2026-09-18); last verified: fpga-kit-sim 9/9 x2 seeds
- [Blocked: needs bench] fpga_bringup   (domain: hardware)  Basys 3 / XC7A35T / Vivado; guide: docs/phase6_fpga_guide.md (now incl. shipped RTL/host code, 6.3); PENDING-HARDWARE until bench evidence

## Target-scores work (2026-09-19; see the change list, every item gated)
- [Ready] benchmark math fix                      (domain: sandbox)  docs/benchmark.md corrected + load-cycle note (review-fixes)
- [Ready] repo hygiene                            (domain: sandbox)  process/, docs/guide.md, README rewrite, diagrams.md
- [Ready] perl ports                              (domain: sandbox)  scripts/*.pl, make perl-crosscheck PASSED 2026-09-19
- [Building] top-level STA                        (domain: sandbox)  make sta-top + scripts/sta_summary.py written; needs yosys/OpenSTA run
- [Building] diagrams                             (domain: sandbox)  Mermaid in README/docs/diagrams.md render on GitHub; WaveDrom JSON needs `make diagrams` (node) for the SVG
- [Building] GitHub Actions CI                    (domain: sandbox)  .github/workflows/ci.yml written; needs a green run on GitHub, then pin OSS_CAD_SHA256
- [Building] exp LUT as block ROM                 (domain: sandbox)  rtl/exp_lut_2p.sv + fpga/exp_lut_2p_xilinx.sv + attention_top PIPE_ROM plumbing; needs make verify (both PIPE_ROM) + Vivado BRAM check
- [Building] UVM environment (matmul_tile)        (domain: sandbox)  tb/uvm written; needs Vivado xsim: smoke, regress, bug-proof
- [Building] VHDL port of mac_unit                (domain: sandbox)  rtl_vhdl/mac_unit.vhd + tb/vhdl_mac; needs make vhdl-crosscheck (ghdl + verilator)
- [Blocked: needs bench] FPGA bring-up (Nexys A7-100T)  (domain: hardware)  fpga/nexys_a7_* + scripts written; make -C fpga hw-gate on the board; PENDING-HARDWARE

## Phase 7: Physical design + silicon
- [Todo] openlane RTL-to-GDS on the tile + KLayout screenshot  (domain: sandbox)  guide: docs/phase7_physical_guide.md
- [Todo] VCD switching-activity power estimate                 (domain: sandbox)  guide: docs/phase7_physical_guide.md section 7
- [Blocked: needs bench] tinytapeout_silicon  (domain: hardware)  ~$100 shuttle seat; guide: docs/phase7_physical_guide.md section 8; PENDING-HARDWARE
