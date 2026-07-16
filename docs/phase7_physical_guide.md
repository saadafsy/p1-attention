# Phase 7: Physical design (OpenLane/Sky130) + the silicon path (beginner guide)

STATUS: NOTHING IN THIS DOCUMENT HAS BEEN EXECUTED. Per the project rule
(CLAUDE.md pre-empted struggle 2), OpenLane is not even installed until
Phases 0 to 5 are done, because its Docker stack is heavy and must not block
core work. Two different honesty levels live in this phase:
- GDS layout, reports, KLayout screenshot, VCD power estimate: SANDBOX
  ACHIEVABLE. Real tool outputs you can produce on this machine and claim
  with evidence rows.
- Fabricated silicon (TinyTapeout): PENDING-HARDWARE plus money. A GDS is a
  blueprint; a chip is a chip. Never blur them.

Audience: never touched a physical design flow. Section 1 is the vocabulary.

## 1. Concepts in one page

RTL to GDS is the pipeline that turns your SystemVerilog into a photomask
layout:

| Stage | What it does | Rough Quartus/FPGA analogy |
|-------|--------------|-----------------------------|
| Synthesis | RTL to a netlist of standard cells (yosys + abc) | Analysis & Synthesis |
| Floorplan | Die/core outline, IO placement, power grid (PDN) | none (FPGA fabric is fixed) |
| Placement | Put each standard cell at x,y | Fitter placement |
| CTS | Build the clock tree from real buffers | (FPGA clock nets are prefab) |
| Routing | Draw the metal wires on ~5 metal layers | Fitter routing |
| Signoff | DRC (geometry legal?), LVS (layout == netlist?), STA, antenna | Assembler + TimeQuest |

- PDK (process design kit): everything foundry-specific: the standard cell
  library (sky130_fd_sc_hd, the same liberty file already staged at
  ~/tools/lib/ for Phase 4 STA), design rules, layer maps. Sky130 is
  SkyWater's open 130 nm process.
- OpenROAD: the engine doing floorplan/place/CTS/route. OpenLane: the
  scripted flow that drives yosys + OpenROAD + magic + netgen end to end
  from one config file.
- GDS (GDSII): the final geometric database, what a foundry consumes.

## 2. Install

Recommended: OpenLane 2 (Python-managed, reproducible):

```bash
python3 -m pip install openlane        # in the asic-venv
# Backend, pick ONE:
#  a) Docker (classic, needs root to install docker once):
#     sudo apt install docker.io && sudo usermod -aG docker $USER  (relogin)
#  b) Nix (no docker, user-space):
#     sh <(curl -L https://nixos.org/nix/install) --daemon   (also needs root once)
```

Note for this machine: no sudo password is available in the sandbox, so the
one-time Docker or Nix installation is a user action on your side; this is a
second reason the phase is gated. The PDK itself (~2-3 GB) is fetched
automatically by OpenLane 2 on first run (via volare) into ~/.volare; no
manual PDK install.

Sanity check the install with their smoke test before touching our design:

```bash
openlane --smoke-test
```

## 3. Configuration for our design

Harden matmul_tile first (self-contained, no ROM include, known-good). Make
a directory phase7/matmul_tile/ with config.json:

```json
{
  "DESIGN_NAME": "matmul_tile",
  "VERILOG_FILES": [
    "dir::../../rtl/mac_unit.sv",
    "dir::../../rtl/matmul_tile.sv"
  ],
  "CLOCK_PORT": "clk",
  "CLOCK_PERIOD": 20,
  "FP_CORE_UTIL": 40,
  "PL_TARGET_DENSITY_PCT": 50
}
```

Notes:
- CLOCK_PERIOD 20 (50 MHz) is a soft first target on 130 nm; tighten after
  the first clean run. Do not start at your dream frequency; start at one
  that routes.
- online_softmax needs the include to resolve: add
  "VERILOG_INCLUDE_DIRS": ["dir::../.."] so `include "rtl/exp_lut.svh"`
  works, exactly like the +incdir in the cocotb flow.
- attention_top hardening is a later exercise: its RAM arrays will synthesize
  to DFF-RAM (huge but legal) unless you map them to sky130 SRAM macros;
  that is an advanced step, not first-run material.

Run:

```bash
cd phase7/matmul_tile && openlane config.json
```

Runs land in runs/RUN_<timestamp>/ with per-stage subdirectories.

## 4. Reading each stage's output (what "good" looks like)

Walk runs/<tag>/ in order; each stage has logs/ and reports/:

| Stage dir | Look at | Good means |
|-----------|---------|------------|
| synthesis | reports/stat.rpt | cell count sane (compare: 867 generic cells from our Phase 1 yosys run), 384 DFFs present, no $mem left |
| floorplan | die area in logs | core fits, utilization near FP_CORE_UTIL |
| placement | density report | no overflow, density near target |
| cts | skew report | skew tens of ps, buffer count modest |
| routing | DRC after route | 0 violations (a handful sometimes clean up in later detailed passes; final must be 0) |
| signoff/magic.drc | violation count | 0 |
| signoff/netgen lvs | reports/lvs.rpt | "Circuits match uniquely" |
| signoff STA | timing summaries per corner | WNS >= 0 at your CLOCK_PERIOD, all corners |
| final/ | gds/, metrics.json | the deliverables |

metrics.json is the machine-readable rollup (area, cell count, WNS, DRC
count); quote numbers from there or from the named reports, never from
memory.

The classic first-run failures and their knobs:
- Congestion/routing overflow: lower FP_CORE_UTIL or PL_TARGET_DENSITY_PCT.
- Setup violations: raise CLOCK_PERIOD first, pipeline second (the softmax
  registered-ROM hook in docs/uarch.md 8.2 exists for exactly this).
- Antenna violations: usually auto-fixed with diodes; a few are normal to
  see mid-flow, zero at signoff.

## 5. The picture: KLayout

```bash
klayout runs/<tag>/final/gds/matmul_tile.gds
```

(KLayout has an Ubuntu package; a userspace AppImage also works.) Turn on a
few metal layers, zoom to show the cell rows and routing, screenshot. That
image plus metrics.json numbers is the honest "took a design through
RTL-to-GDS on Sky130" artifact. Evidence row:

| gds-matmul_tile | RTL-to-GDS clean on sky130 (DRC 0, LVS match, WNS >= 0 at 50 MHz) | PASS | openlane run <tag>, metrics.json, KLayout screenshot docs/gds/ | 0 |

## 6. One timing-closure iteration (the deliverable the build sheet asks for)

1. Run once at CLOCK_PERIOD 20; record WNS from signoff STA.
2. Tighten to the failing edge (e.g. 10 ns), rerun, record the violation.
3. Apply ONE fix (pipeline stage or util/density change), rerun, record
   before/after in a small table.
That table (period, WNS, what changed) is the "did one timing iteration"
claim, backed by two run tags.

## 7. VCD switching-activity power estimate

Replaces the Phase 5 toggle-count proxy with real numbers:

1. Gate-level sim: take the synthesized netlist
   (runs/<tag>/synthesis/*.nl.v or the powered final netlist) plus the
   sky130 cell Verilog models (from the PDK,
   sky130_fd_sc_hd.v primitives), simulate your existing stimulus with
   iverilog, and dump a VCD ($dumpfile/$dumpvars in a small GLS wrapper).
   Reuse the cocotb stimulus by replaying a recorded vector file if cocotb
   GLS is fiddly; identical stimulus matters more than the harness.
2. Power: OpenSTA (already at ~/.local/bin/opensta) with the liberty file:

```tcl
read_liberty ~/tools/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
read_verilog runs/<tag>/final/nl/matmul_tile.nl.v
link_design matmul_tile
read_sdc  <the run's sdc>
read_power_activities -vcd gls.vcd
report_power
```

3. Run it twice, naive vs pipelined variant, same stimulus, and tabulate.
   That is the honest "switching-activity power comparison" (still a tool
   estimate at typical corner: say so; it is not a bench measurement).

## 8. TinyTapeout: the silicon path (PENDING-HARDWARE + money)

What it is: a community shuttle that aggregates hundreds of tiny designs
onto one Sky130 chip via chipIgnite. You buy a tile, submit a hardened
macro, and months later receive a real chip on a dev board.

The constraints that shape the design:
- A 1x1 tile is about 160 x 100 um and has 8 dedicated inputs, 8 dedicated
  outputs, and 8 bidirectional pins. Larger multiples can be bought.
- Clock comes from the TT harness (configurable, tens of MHz realistic).
- 8-in/8-out means our 64-bit-per-cycle interfaces MUST be serialized: a
  byte-wide load protocol (the attention_top write port maps naturally:
  8-bit data in, use bidir pins for address/control strobes, 8-bit result
  readout). Budget a small TT wrapper module for this; design it like the
  UART wrapper of Phase 6 but parallel-byte instead of serial-bit.
- Area: matmul_tile's ~400 FFs plus logic will need a 1x2 or 2x2 tile;
  check the utilization report from a trial hardening before buying.

Cost and timeline, honestly: on the order of $100 to $300 for tile +
dev board + shipping (check current pricing at tinytapeout.com), shuttles
run a few times per year with hard submission deadlines, and fabricated
chips arrive roughly 6 to 12 months later.

Submission mechanics:
1. Fork the current TT template repo (tinytapeout.com links the live one;
   the top module must be named tt_um_<yourname>_<design>).
2. Drop in the RTL + wrapper, fill info.yaml (pinout, description, how to
   test).
3. Push: the template's GitHub Actions runs the SAME OpenLane hardening you
   ran locally and publishes GDS + reports as artifacts. Green CI = valid
   submission.
4. Register the project on the TT app before the shuttle deadline, pay,
   done.
5. When the chip arrives: the measurement plan is a clock sweep
   (functional ceiling vs the STA prediction) and a measured-vs-simulated
   table on the same vectors. THAT, and only that, converts
   tinytapeout_silicon from [Blocked: needs bench] to a real
   post-silicon-validation claim, with photos and the sweep data as the
   EVIDENCE row artifacts.

## 9. Claim ledger for this phase

| Artifact | Claimable as | Status gate |
|----------|--------------|-------------|
| Clean OpenLane run (DRC 0, LVS match) | "took the design through RTL-to-GDS on Sky130" | sandbox, needs run + row |
| KLayout screenshot | portfolio image of the layout | sandbox, with the run it came from |
| STA at signoff | "timing closed at X MHz in the open flow (tool report)" | sandbox; never call it measured |
| OpenSTA + VCD power table | "switching-activity power estimate, naive vs pipelined" | sandbox; an estimate, say so |
| TT submission accepted | "submitted to a Sky130 shuttle" | needs money + deadline |
| Chip on desk + clock sweep | "fabricated and characterized on silicon" | PENDING-HARDWARE until the chip is measured |
