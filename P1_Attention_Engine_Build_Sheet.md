# PROJECT 1 BUILD SHEET
## Streaming Attention Engine — full RTL-to-silicon stack
Single project, phased. Each phase closes specific ASIC-internship requirement bullets.
Simulation-first, free tools, no soldering. AI = tutor only (you write all rtl/ and formal/).

**One-line pitch (final form):**
A fixed-point streaming attention accelerator (online softmax + tiled matmul) in SystemVerilog,
verified with UVM + constrained-random + functional coverage against C++/NumPy golden models,
synthesized and timing-closed (Yosys/OpenSTA), taken through a full RTL-to-GDS flow (OpenLane/Sky130),
demonstrated on FPGA, and optionally taped out on TinyTapeout.

**HARD RULE:** Phases 6-7 (FPGA / physical design / tapeout) do NOT start until Phases 0-5 are DONE.
Core RTL + verification is the meal. Physical design is garnish. Never garnish before the meal.

---

### PHASE 0 — Golden models + fixed-point study (weeks 1-2)
- Study fixed-point: quantization, accumulator width, rounding, saturation.
- Write the reference TWICE: `model/attn.py` (NumPy) and `model/attn.cpp` (C++). Unit-test them against each other on random inputs.
- Deliverable: two bit-agreeing golden models + a doc note on the number format chosen and why.
- COVERS: computer arithmetic; C++ (100% of AMD JDs); Python; golden/reference-model methodology; OOP (C++).

### PHASE 1 — Core datapath RTL (weeks 3-5)
- Build up: MAC unit -> small weight-stationary matmul tile -> online-softmax pipeline (running max + rescale).
- Self-checking testbench in `tb/` compares RTL output to the golden models.
- Deliverable: `rtl/` blocks passing directed tests vs golden model.
- COVERS: Verilog/SystemVerilog; RTL design; digital logic fundamentals; testbench creation; AI-hardware domain.

### PHASE 2 — Integration + benchmark (weeks 6-7)
- Stitch tile + softmax into the streaming attention datapath (tile-by-tile with denominator exchange).
- Cycle-count benchmark vs the CPU golden model; record speedup.
- Deliverable: working end-to-end engine + a benchmark table.
- COVERS: microarchitecture/dataflow reasoning; performance analysis (throughput).

### PHASE 3 — UVM verification [UPGRADE 1+2] (weeks 8-9)
- Build a UVM testbench for the softmax block: agent, driver, monitor, scoreboard.
- Add covergroups + constrained-random stimulus; drive to coverage closure; record the numbers.
- Deliverable: UVM env in `tb/uvm/`, coverage report.
- COVERS: UVM (dominant in AMD Markham / Qualcomm / Apple / Ambarella DV roles); constrained-random + functional coverage; verification environments; OOP (SV classes).

### PHASE 4 — Synthesis + STA [UPGRADE 4] (week 10)
- Yosys synthesis -> gate-level netlist; OpenSTA for setup/hold, report fmax + area.
- Run ONE gate-level simulation (netlist + Icarus) to close the "gate-level sim failures" bullet.
- Do one pipelining iteration to improve timing; publish before/after table.
- Deliverable: synthesis + timing report, before/after fmax.
- COVERS: synthesis; STA / timing awareness (setup/hold); gate-level sim debug; "I closed timing on my own design."

### PHASE 5 — Verification plan + power proxy [UPGRADE 5] (week 11)
- Write the 1-page verification plan (features, stimulus strategy, checkers, coverage goals) — retroactively formalized.
- Power proxy: toggle-count naive vs pipelined datapath.
- Deliverable: `docs/verification_plan.md` + a tradeoffs writeup.
- COVERS: test planning (Intel/AMD intern task); power analysis (intro); technical communication.

--- CORE COMPLETE ABOVE THIS LINE. Everything below is garnish. ---

### PHASE 6 — FPGA prototype (optional, ~2 weekends)
- Port the systolic tile to an FPGA board (digital-design course board or cheap iCE40/Artix).
- Deliverable: "demonstrated on FPGA" + a short bring-up note.
- COVERS: FPGA (always "a plus"); emulation-adjacent answer.

### PHASE 7 — Physical design + silicon [closes PD/CMOS/power bullets] (~2-3 weekends)
- 7a. OpenLane/OpenROAD full flow on the tile (or the P2 FIFO): synthesis -> floorplan -> placement -> CTS -> routing -> GDS on Sky130. One timing-closure iteration. Open layout in KLayout; screenshot.
  - COVERS: CAD / physical-design methodology; P&R; RTL-to-GDS flow — honestly, via the open flow.
- 7b. VCD switching-activity power estimate (Yosys): real numbers, naive vs pipelined, replaces the proxy.
  - COVERS: power analysis (real).
- 7c. (Optional, ~$100, shuttle-dependent) TinyTapeout submission of the tile/FIFO: fabricated Sky130 silicon + devkit measurement plan (clock sweep, measured-vs-sim table).
  - COVERS: silicon instrumentation / post-silicon validation; standard-cell/CMOS talking points (Sky130 PDK); the rarest undergrad line — taped-out silicon.
- 7d. (Optional add-ons if chasing full 100%) OpenROAD PDN + static IR-drop (the honest "noise" bullet); Fault ATPG on the netlist for scan/fault-coverage (DFT bullet); xschem+ngspice inverter/ring-osc on Sky130 (CMOS artifact).

### EXPLICITLY NOT CHASED
Commercial signoff (crosstalk SI, IR-drop on PrimeTime-SI/Tempus/Voltus), emulation platforms
(Palladium/Zebu), advanced-node tapeout, volume bring-up. Employment-only; interview-safe one-line
answers documented in the main database. No design/DV posting expects these of a 2nd/3rd-year.

---

## RESUME BULLETS (once done)
- Designed a fixed-point streaming attention accelerator (online softmax + tiled matmul) in SystemVerilog; benchmarked N× over CPU; verified against C++/NumPy golden models.
- Built a UVM testbench (agent/driver/monitor/scoreboard) with constrained-random stimulus and functional-coverage closure for the softmax datapath.
- Synthesized with Yosys and improved fmax N% via pipelining (OpenSTA); ran gate-level simulation for netlist sign-off.
- Took the design through a full RTL-to-GDS flow (OpenLane, Sky130) with timing closure; [taped out on TinyTapeout and characterized on silicon].

## DEFINITION OF DONE (whole project)
Golden-model match; UVM + coverage + (optional) formal; synthesis/timing data; GDS layout; a tradeoffs
writeup; and the interview bar — you can defend EVERY design decision to a hostile senior engineer, no notes.
