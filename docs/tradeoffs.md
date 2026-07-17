# Tradeoffs: naive vs pipelined online_softmax (Phase 4/5)

Status: Phase 5 deliverable. Compares the two elaborations of
rtl/online_softmax.sv introduced in Phase 4 (docs/uarch.md 8.2.1): PIPE_ROM=0,
the naive single-cycle comb-ROM recurrence, and PIPE_ROM=1, the registered-ROM
two-stage variant. All numbers in this file are SANDBOX TOOL ESTIMATES at the
sky130_fd_sc_hd tt_025C_1v80 corner (yosys mapping, OpenSTA 2.0.17, ideal
clock, zero-margin I/O). Nothing here is a hardware measurement; no FPGA or
silicon evidence exists. Evidence rows: [EVIDENCE: phase4-sta],
[EVIDENCE: phase5-docs].

## 1. What was compared and how

Both configs were taken through the identical flow on 2026-07-16:

1. Synthesis: yosys synth + dfflibmap + abc to sky130_fd_sc_hd
   (build/synth_netlist_online_softmax*.log). PIPE_ROM=1 is elaborated with
   chparam; the netlists keep the same module name and ports.
2. STA: OpenSTA, scripts/sta.tcl, at 10 ns and at each config's met period
   (build/sta_online_softmax*.log).
3. GLS: both netlists replay the SAME 549-cycle spec-derived golden vector
   set (scripts/gen_gls_vectors.py, from the normative uarch.md 8.2/8.2.1
   text and model/attn.py primitives, not from the RTL) under iverilog with
   the sky130 FUNCTIONAL cell models: 546 checked cycles, 0 errors each
   (make -C tb/gls all, build/gls_lat*.log). The runs dump the VCDs used
   below, so the activity comparison is identical-stimulus by construction.
4. Switching activity: 0-to-1/1-to-0 transition counts over all ~25k dumped
   nets per netlist (scripts/toggle_count.py).
5. Power proxy: OpenSTA report_power with the measured average activity
   applied globally via set_power_activity (scripts/power_proxy.tcl). This
   opensta build predates read_power_activities, so per-net VCD annotation
   is not possible; the estimate is calibrated by measured AVERAGE activity
   only. Zero-delay functional GLS also collapses same-timestep glitches,
   so combinational glitch power is invisible to both the toggle counts and
   the calibrated estimate (see section 4).

## 2. Results

Timing, area (sky130 tt, zero-margin I/O, ideal clock):

| metric                    | PIPE_ROM=0 naive | PIPE_ROM=1 pipelined | delta |
|---------------------------|------------------|----------------------|-------|
| setup slack at 10 ns      | -15.574 ns       | -2.664 ns            |       |
| met period (setup+hold)   | 26 ns            | 13 ns                |       |
| Fmax (tool estimate)      | 38.5 MHz         | 76.9 MHz             | 2.0x  |
| critical path             | m reg through diff, clamp, ROM, multiply, rshr, add into l reg | m reg through diff, clamp, ROM into w_p pipe reg | cut at ROM output |
| cells                     | 3842             | 3817                 | -0.7% |
| flip-flops                | 73               | 107                  | +47%  |
| area (um2)                | 24587            | 26881                | +9.3% |
| out_valid latency         | 1 cycle          | 2 cycles             | +1    |
| throughput                | 1 elem/cycle     | 1 elem/cycle         | none  |

Switching activity, identical 549-cycle stimulus (546 checked):

| metric              | PIPE_ROM=0 | PIPE_ROM=1 | delta |
|---------------------|------------|------------|-------|
| dumped nets         | 25317      | 25953      | +2.5% |
| total toggles       | 388779     | 393472     | +1.2% |
| toggles/net/cycle   | 0.0281     | 0.0278     | -1.3% |

Power proxy (OpenSTA report_power, global activity calibrated from the row
above, duty 0.5; a coarse tool estimate, see section 1 item 5):

| operating point               | PIPE_ROM=0 | PIPE_ROM=1 | delta |
|-------------------------------|------------|------------|-------|
| at own met Fmax               | 0.365 mW @ 38.5 MHz | 0.954 mW @ 76.9 MHz | 2.6x |
| iso-frequency (both at 38.5)  | 0.365 mW   | 0.477 mW   | +31%  |
| energy per element (period x power) | 9.5 pJ | 12.4 pJ   | +31%  |

Logs: build/power_proxy_lat1_26ns.log, build/power_proxy_lat2_13ns.log,
build/power_proxy_lat2_26ns.log.

## 3. Reading the numbers

- The one pipelining iteration buys 2.0x Fmax for +9% area. The stage cut
  lands exactly where uarch.md 8.2.1 specifies (verified in the STA path:
  the PIPE_ROM=1 worst path ends at the w_p pipe register and the multiply
  is off it).
- The activity cost of pipelining is negligible (+1.2% toggles on identical
  work). The power-proxy cost is not: +31% at iso-frequency, dominated by
  the internal (clock-pin) power of 34 extra flops in an estimate where
  sequential internal power is 87 to 90 percent of the total.
- Energy per element rises 31% in the proxy. The pipelined config is a
  latency/frequency win, not an energy win: choose PIPE_ROM=1 when the
  system clock demands it, keep PIPE_ROM=0 when 38 MHz suffices and energy
  or latency-1 alignment matters. attention_top instantiates the default
  PIPE_ROM=0 and is unchanged (uarch.md 8.2.1).
- Neither config meets the 10 ns period that mac_unit and matmul_tile meet
  (+4.101 ns each). The softmax recurrence remains the whole design's Fmax
  limiter even pipelined; closing 10 ns would need a second cut through the
  multiply/rshr/add stage (out of Phase 4 scope, which is one iteration).

## 4. Known biases of the proxy

- Zero-delay GLS hides glitches: the comb-ROM config's long multiply cone
  sees unregistered ROM outputs and will glitch more in real timing than in
  this proxy, so the proxy likely UNDERSTATES the naive config's dynamic
  power. The registered-ROM variant feeds the multiplier from flops, which
  suppresses that class of glitching. The real iso-frequency power gap is
  therefore plausibly smaller than +31%, and could favor PIPE_ROM=1 more
  than shown; the sign cannot be resolved without SDF-annotated GLS or
  silicon.
- Global-average activity flattens per-net variation; the ideal clock means
  no clock-tree power on either side (it would scale with the +47% flops).
- tt corner only; no wire parasitics (no placement or routing exists at
  this phase).

These limits are inherent to Phase 5. The Phase 7 OpenLane flow upgrades
this comparison with routed parasitics and, with a newer OpenSTA, per-net
VCD annotation (docs/phase7_physical_guide.md section 7).
