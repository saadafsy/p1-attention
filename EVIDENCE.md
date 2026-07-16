# EVIDENCE ledger

The verify targets append rows here. The technical-writer reads this and may only make
claims backed by a PASS row. Hardware/silicon claims stay PENDING-HARDWARE until you add
a row with real bench evidence.

| id | claim | status | command / artifact | exit |
|----|-------|--------|--------------------|------|
| verify-tool_smoke | tool_smoke passes lint/sim/cov/synth/formal | PASS | make verify MODULE=tool_smoke | 0 |
VERIFY OK: tool_smoke
| model-crosscheck | attn.py and attn.cpp bit-identical on random + corner cases; exp LUT emitted; float gate met | PASS | make model-check | 0 |
VERIFY OK: attn_model
| model-crosscheck | attn.py and attn.cpp bit-identical on random + corner cases; exp LUT emitted; float gate met | PASS | make model-check | 0 |
VERIFY OK: attn_model
| verify-mac_unit | mac_unit passes lint/sim/cov/synth/formal | PASS | make verify MODULE=mac_unit | 0 |
VERIFY OK: mac_unit
| audit-mac_unit-lint-synth | lint-synth-auditor independent re-run: verilator+verible lint clean, yosys check 0 problems, no $_DLATCH_, netlist latch-free | PASS | agent re-ran make lint + make synth-check + yosys synth, 2026-07-16 | 0 |
| audit-mac_unit-formal-coverage | formal-coverage-auditor independent re-run: cocotb 4/4 on two seeds, line coverage 100%, sby BMC PASS; gaps noted in report | PASS | agent re-ran make sim (SEED=1,7) + check_coverage + sby, 2026-07-16 | 0 |
| verify-matmul_tile | matmul_tile passes lint/sim/cov/synth/formal | PASS | make verify MODULE=matmul_tile | 0 |
VERIFY OK: matmul_tile
| audit-matmul_tile-lint-synth | lint-synth-auditor independent re-run: multi-file lint clean, yosys check 0 problems, no $_DLATCH_, netlist 384 FF latch-free, packing/signedness verified vs uarch 8.1 | PASS | agent re-ran make lint + make synth-check + yosys synth, 2026-07-16 | 0 |
| audit-matmul_tile-formal-coverage | formal-coverage-auditor independent re-run: cocotb 6/6 on two genuinely different seeds, tile line coverage 100%, sby BMC depth5 PASS; chformal reduction audited non-vacuous and justified | PASS | agent re-ran make sim (SEED=1,7) + check_coverage + sby + SMT2 inspection, 2026-07-16 | 0 |
| model-crosscheck | attn.py and attn.cpp bit-identical on random + corner cases; exp LUT emitted; float gate met | PASS | make model-check | 0 |
VERIFY OK: attn_model
| verify-online_softmax | online_softmax passes lint/sim/cov/synth/formal | PASS | make verify MODULE=online_softmax | 0 |
VERIFY OK: online_softmax
| audit-online_softmax-lint-synth | lint-synth-auditor independent re-run: lint clean, yosys check 0 problems, no $_DLATCH_, netlist latch-free (73 FFs), arithmetic verified vs uarch 6/3.5, generated ROM diff-identical to emitter | PASS | agent re-ran make lint + make synth-check + yosys synth + emitter diff, 2026-07-16 | 0 |
| audit-online_softmax-formal-coverage | formal-coverage-auditor independent re-run: cocotb 7/7 on two seeds, coverage 99.9% (sole miss = unreachable generated default arm, verified), sby depth20 PASS non-vacuous; alignment and rescale-identity checks audited | PASS | agent re-ran make sim (SEED=1,7) + check_coverage + sby + SMT2 inspection, 2026-07-16 | 0 |
