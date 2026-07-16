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
