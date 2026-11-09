# tb/uvm: a UVM environment for matmul_tile

A second verification environment for one module, beside the cocotb suite
that remains the regression and golden-model check for the full design.

Status: compiled and run on Verilator 5.053 with Accellera UVM
1800.2-2017-1.0 (`make -C tb/uvm gate SIM=verilator`, EVIDENCE.md row
uvm-verilator-20260928). Merged coverage has not been run and Vivado xsim
has not been used.

## What is here

| File | Role |
|------|------|
| tile_if.sv | interface with driver/monitor clocking blocks and an edge counter |
| tile_seq_item.sv | one edge of stimulus: rand rst/en/clr, rand Q1.6 q[4]/k[4] with edge-weighted constraints; golden and observed acc |
| tile_sequence.sv | tile_replay_sequence (drives a Python-generated golden file) and tile_random_sequence (constrained-random dot products, bubbles, clears, resets); tile_sequencer typedef |
| tile_driver.sv | one item per edge, publishes driven items for the scoreboard |
| tile_monitor.sv | observed transaction per edge (stimulus + resulting acc), optional trace file |
| tile_agent.sv, tile_env.sv | agent and env wiring |
| tile_scoreboard.sv | pairs driven and observed edges; compares all 16 accumulators against the golden columns (replay) or checks the control contract only (random); uvm_fatal on any error |
| tile_coverage.sv | covergroups: operand signs and cross, Q1.6 magnitude classes x lane, clr/en control rows, dot-product length (incl. full-16 and beyond-16), hold transitions, SACC magnitude classes x lane |
| tile_assertions.sv | SVA bound to mac_unit (contract rows, no-overflow, no hidden latency) and matmul_tile (bus-wide reset/clear/hold) |
| tb_top.sv | interface + DUT + uvm_config_db handoff + run_test; $fatal if any UVM error was reported |
| tile_uvm_pkg.sv | package that includes the class files |
| scripts/run_xsim.sh, scripts/run_verilator.sh, scripts/merge_coverage.sh | compile/run per simulator and xcrg merge |
| vectors/tile_seed_17.txt | golden vectors from scripts/gen_tile_uvm_vectors.py (`make vectors SEED=17`) |

## Golden values come from Python

There is no SystemVerilog reference model of the MAC; the reference is
model/attn.py and its mirror.

1. Replay test: `scripts/gen_tile_uvm_vectors.py --emit` writes stimulus and
   the expected acc_flat after every edge; the scoreboard compares in-sim.
2. Random test: SV constraints generate stimulus, the monitor writes a trace,
   and `scripts/gen_tile_uvm_vectors.py --check` recomputes it afterwards.
   In-sim the scoreboard still checks reset, clear and hold.

There are no saturation or rounding bins: matmul_tile accumulates exactly
(docs/uarch.md 8.1). Those corners are covered in tb/attention_top.

## Simulator

Vivado xsim ships UVM 1.2. Its coverage switches and xcrg's merge support
vary by release, so run `make -C tb/uvm smoke` first; merge_coverage.sh
fails rather than summing per-seed percentages if merging is unavailable.
`SIM=verilator` uses run_verilator.sh and produces no coverage.

## Evidence gate

```
source /opt/Xilinx/Vivado/<ver>/settings64.sh
make -C tb/uvm smoke
make -C tb/uvm gate UVM_SEEDS=10
```

`gate` runs `regress` (seeds x replay + random, then merged coverage) and
`bug-proof` (mac_unit built with INJECT_BUG, whose load ignores clr; the
replay test must fail). Record the simulator version, merged coverage and
bug-proof log lines in the EVIDENCE.md row before claiming the result.
