# Phase 6: FPGA prototype on the Basys 3 (complete beginner guide)

STATUS: NOTHING IN THIS DOCUMENT HAS BEEN EXECUTED. This is a forward-looking
instruction guide. Every result described here is PENDING-HARDWARE until you
run it on the physical board and record bench evidence (photo/video, ILA
captures, the timing report) in EVIDENCE.md. Until then the only honest claim
remains: verified in simulation and formal; synthesized to a latch-free
netlist; not implemented on FPGA.

Audience: you have used Quartus but never Vivado. Differences are called out
explicitly. Time budget: one weekend for tool install + first bitstream, one
weekend for real bring-up.

## 1. What you need

| Item | Detail |
|------|--------|
| Board | Digilent Basys 3 (Artix-7 XC7A35T-1CPG236C) |
| Cable | Micro-USB (programs AND powers the board, JTAG over USB) |
| Tool | AMD Vivado ML Standard Edition (free, no license file needed for Artix-7) |
| Disk | 60 to 100 GB free during install (the installer is huge; final ~40 GB) |
| OS | Linux or Windows both fine; this guide assumes Linux paths |

Install: download the "Vivado ML Standard" web installer from amd.com
(account required, free). In the installer select only Vivado (not Vitis) and
only the 7 Series device family to keep the size down. The Basys 3 does not
need Digilent board files to work (we pin every pin in the XDC ourselves),
but installing them makes the project wizard friendlier: clone
https://github.com/Digilent/vivado-boards and copy board_files/ into
<Vivado>/data/boards/.

## 2. Quartus-to-Vivado translation table

| Quartus concept | Vivado equivalent |
|-----------------|-------------------|
| .qsf assignments | XDC file (Tcl-like constraint language) |
| Pin Planner | XDC set_property PACKAGE_PIN lines (or Layout > I/O Planning) |
| .sof/.pof | .bit bitstream (.bin/.mcs for flash) |
| Programmer | Hardware Manager |
| SignalTap II | ILA (Integrated Logic Analyzer) IP |
| In-System Sources and Probes | VIO (Virtual Input/Output) IP |
| PLL megafunction | Clocking Wizard IP (MMCM/PLL) |
| TimeQuest | report_timing_summary (same SDC-style constraints) |
| Analysis and Synthesis | Run Synthesis |
| Fitter | Run Implementation (place + route) |

The mental model is the same: constrain the clock, pin the I/O, synthesize,
place and route, read the timing report, program. Vivado's constraint syntax
IS SDC (like TimeQuest), so create_clock will look familiar.

## 3. What to put on the board, and will it fit

Start with matmul_tile plus a small wrapper. It is the verified, self-contained
compute block and it fits with enormous headroom:

| Resource | XC7A35T has | matmul_tile needs (estimate) |
|----------|-------------|------------------------------|
| LUT6 | ~20,800 | a few hundred (plus wrapper) |
| FF | ~41,600 | 384 (16 x 24-bit SACC) + wrapper |
| DSP48E1 | 90 | up to 16 (one per 8x8 multiply; synth may LUT them) |
| BRAM36 | 50 | 0 |

A trimmed attention_top (once it exists and is verified) also fits: the exp
ROM is 2 KB (one BRAM18 or distributed LUTROM), the softmax multiplier maps
to 1 or 2 DSPs, the PV array to ~32 DSPs. Do the tile first anyway: fewer
moving parts on first bring-up.

These are paper estimates, not tool reports. Record actual utilization from
Vivado's post-implementation report when you run it (PENDING-HARDWARE).

## 4. Project setup, click by click

1. Vivado > Create Project > RTL Project, do NOT specify sources yet.
2. Part selection: search xc7a35tcpg236-1 (or pick Basys 3 under Boards if
   you installed board files).
3. Add Sources > Add or create design sources > add:
   - rtl/mac_unit.sv
   - rtl/matmul_tile.sv
   - your wrapper (section 6)
   - (only if building the softmax/top) rtl/online_softmax.sv and
     rtl/exp_lut.svh
4. exp_lut.svh handling: select it in the Sources window, right-click >
   Source File Properties > set Type to "Verilog Header". Vivado must not
   compile it standalone. Because the RTL includes it as
   `include "rtl/exp_lut.svh"` (repo-root-relative), add the REPO ROOT as an
   include directory: Settings > General > Verilog options > Verilog Include
   Files Search Paths > add /path/to/p1-attention. (Quartus analogy: the
   .qsf SEARCH_PATH assignment.)
5. Add Sources > Add or create constraints > create basys3.xdc (section 5).
6. Set the wrapper as top (right-click > Set as Top; Vivado usually guesses).

## 5. The XDC file

Basys 3 pin facts used below: 100 MHz oscillator on W5, center button on U18,
switches from V17 up, LEDs from U16 up, USB-UART bridge RX=B18 (host to
FPGA), TX=A18 (FPGA to host). Full reference: the Digilent Basys-3-Master.xdc
on GitHub (Digilent/digilent-xdc).

```tcl
## 100 MHz system clock
set_property PACKAGE_PIN W5 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -name sys_clk -period 10.000 [get_ports clk]

## reset: center button (active high when pressed)
set_property PACKAGE_PIN U18 [get_ports rst_btn]
set_property IOSTANDARD LVCMOS33 [get_ports rst_btn]

## USB-UART (only if you build the UART wrapper)
set_property PACKAGE_PIN B18 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]
set_property PACKAGE_PIN A18 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]

## a heartbeat LED so you can see the design is alive
set_property PACKAGE_PIN U16 [get_ports led0]
set_property IOSTANDARD LVCMOS33 [get_ports led0]

## configuration voltage (Vivado warns without these)
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
```

Two Quartus-user traps:
- Every I/O needs an IOSTANDARD or bitstream generation FAILS (Quartus
  defaults these; Vivado refuses).
- The button is mechanical: synchronize it into the clock domain (two FFs)
  and treat the synchronized signal as your rst. Our RTL uses synchronous
  active-high reset, so a pressed button = rst high is the right polarity.

## 6. Getting Q/K/V in and results out

The tile consumes 64 bits/cycle of operands and exposes 384 bits of
accumulator. The board has 16 switches and 16 LEDs. Do not try to map buses
to pins. Two workable paths, in recommended order:

### 6.1 First bring-up: VIO + ILA (no new RTL, SignalTap-style)

- VIO (like In-System Sources and Probes): IP Catalog > VIO > one output
  port per DUT input (en, clr, q_flat[31:0], k_flat[31:0]). You poke values
  from the Vivado GUI over JTAG.
- ILA (like SignalTap): IP Catalog > ILA > probe acc_flat[383:0] plus your
  controls, sample depth 1024, trigger on clr rising.
- Wire wrapper: VIO outputs -> DUT inputs, DUT outputs -> ILA probes.
- Flow on hardware: set a known Q/K vector pattern in VIO, pulse clr+en for
  16 cycles (add a tiny FSM that plays 16 elements from a constant array so
  timing is exact), capture acc_flat in ILA, compare against
  model/attn.py's dot products by hand.
- This proves: clocking, reset, the datapath computing on real silicon
  (FPGA fabric), and your ability to observe it. That is the whole point of
  Phase 6.

### 6.2 Real demo: UART loader (the portable story)

Write a uart_wrapper.sv around the tile (or later attention_top's load
ports): 115200 baud 8N1.
- RX path: a standard UART receiver (16x oversample of the 100 MHz clock,
  divider 100e6/115200 ~= 868), byte protocol: [cmd][payload...]. Commands:
  load Q row, load K row, run N cycles, read result.
- TX path: stream acc_flat back as 48 bytes (16 x 24-bit, low byte first).
- Host side: a 30-line Python script with pyserial that loads vectors,
  triggers, reads back, and asserts equality against model/attn.py. That
  script IS your self-checking hardware test.
- attention_top's memory-load write port (sel/addr/data/we) was designed for
  exactly this kind of byte-serial front end.

## 7. Synthesis, implementation, bitstream

GUI path: Run Synthesis > Run Implementation > Generate Bitstream (each
prompts the next). Tcl console equivalent:

```tcl
launch_runs synth_1 -jobs 8; wait_on_runs synth_1
launch_runs impl_1 -jobs 8;  wait_on_runs impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8; wait_on_runs impl_1
```

Check AFTER synthesis, before going further:
- Messages window: zero critical warnings you cannot explain. Especially
  hunt "inferred latch" (should be impossible; our lint gate bans them) and
  "multi-driven net".
- Utilization report: sanity-check against the section 3 estimates.

## 8. Reading timing (the honest Fmax)

Open Implemented Design > Report Timing Summary. The one number that
matters: WNS (worst negative slack) under Setup.
- WNS >= 0: you met 100 MHz. The achievable Fmax estimate is
  1 / (10 ns - WNS). Quote it as "met 100 MHz with X ns setup slack on
  XC7A35T-1 (Vivado report_timing_summary)".
- WNS < 0: you failed 100 MHz. Either slow the clock constraint (the Basys 3
  clock can be divided down with a Clocking Wizard MMCM) or pipeline. For
  the softmax path, docs/uarch.md 8.2 already reserves the registered-ROM
  pipelining hook as the designed fix.
- Also glance at hold (WHS >= 0; router fixes hold automatically almost
  always) and the unconstrained-paths section (should list nothing you care
  about).

Claim discipline: an FPGA timing report is still a TOOL result. "Runs at 100
MHz on the board" additionally requires the design to actually function on
hardware at that clock (section 9). Both go in the same EVIDENCE row.

## 9. Programming and bring-up

Program: open Hardware Manager > Open Target > Auto Connect (board plugged
in, power switch ON, driver installed automatically by Vivado) > Program
Device > select the .bit. The DONE LED lights when configuration succeeds.

### Debugging by symptom

| Symptom | Likely cause, in order |
|---------|------------------------|
| Hardware Manager sees no target | Board off, cable is power-only micro-USB, or Linux udev permissions (install Digilent cable drivers / add udev rules) |
| Programming succeeds, DONE dark | Wrong part selected; CFGBVS/CONFIG_VOLTAGE lines missing |
| Design totally dead, heartbeat LED off | Clock not toggling (wrong pin, W5 typo), or reset stuck: check the button polarity and your synchronizer |
| ILA never triggers | Trigger condition wrong, or clr/en never asserted: probe the FSM state too, trigger on state changes |
| ILA shows garbage/X-like values | Reset never released, ROM include misconfigured (softmax builds), or you probed pre-synth names that got renamed: use (* mark_debug = "true" *) on nets you must keep |
| UART prints garbage | Baud divisor arithmetic (868, not 867), missing 2-FF synchronizer on uart_rx, byte order confusion on the 24-bit words |
| Works in sim, wrong numbers on board | Uninitialized RAM/regs (Verilator is 2-state and forgiving; hardware is not: check every FF has reset), a real CDC (button/UART inputs not synchronized), or timing failure you ignored |
| Random wrong answers, temperature/touch dependent | You ignored WNS < 0. Fix timing; never ship a failing-timing bitstream as "working" |

### First-silicon checklist (order matters)
1. Heartbeat LED blinks (clock + reset alive).
2. VIO writes reach the DUT (read them back on ILA).
3. One hand-computed 16-cycle dot product matches model/attn.py.
4. 100 random vectors from the host script match (UART path).
5. Save: ILA waveform screenshot, timing summary, utilization report, a
   photo/video of the board running the host script.

## 10. What counts as evidence (the wall stays up)

When and only when step 9 passes on the physical board, append to
EVIDENCE.md something like:

| fpga-bringup-matmul_tile | tile computes correct dot products on Basys 3 at 100 MHz | PASS | host script vs model/attn.py, N vectors; Vivado timing summary WNS=+X ns; photos/ILA captures in docs/bench/ | 0 |

Until that row exists, everything in this file is a plan, the PLAN.md row
stays [Blocked: needs bench], and no FPGA claim may appear in guide.md or a
resume bullet. The audit-guide hook enforces this for guide.md; you enforce
it everywhere else.
