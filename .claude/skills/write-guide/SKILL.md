---
name: write-guide
description: Generate or refresh guide.md from artifacts and EVIDENCE.md, at reference-guide depth.
---
Delegate to the technical-writer subagent. Regenerate guide.md following the contract in
technical-writer.md and the rubric in asic-guide-fidelity-rubric.md. Do not invent numbers
or bench results. End by running `make audit-guide` and report the exit code.
