#!/usr/bin/env bash
# Run once from the root of your ASIC repo:  bash setup-p1.sh
# Creates the Alpha/Beta agent roster, the audit hooks, PLAN.md and EVIDENCE.md.
# It NEVER overwrites an existing file: every artifact below is written only if
# absent (2026-09-18, review finding L6: the original unconditionally rewrote
# .claude/settings.json, dropping the statusLine entry, and every agent file).
# Delete a file first if you want the scaffold version back.
set -euo pipefail

mkdir -p .claude/agents .claude/hooks .claude/skills/write-guide

# ---------------------------------------------------------------------------
# TEAM ALPHA (builders, may edit files)
# ---------------------------------------------------------------------------

if [ ! -f .claude/agents/rtl-designer.md ]; then
cat > .claude/agents/rtl-designer.md << 'EOF'
---
name: rtl-designer
description: Writes and fixes synthesizable SystemVerilog RTL to the project standards. Use for implementation tasks on a single module.
tools: Read, Write, Edit, Bash, Grep, Glob
model: opus
---
You implement one RTL module at a time for the Streaming Attention Engine, per CLAUDE.md.
Build order: mac_unit -> matmul_tile -> online_softmax -> attention_top.
- Synthesizable only: no inferred latches (every always_comb assigns all outputs on
  all paths or has a default), reset every sequential element, no initial blocks in RTL.
- Fixed-point: document Q-format, accumulator width, rounding, and saturation for every
  datapath block; these are the load-bearing facts the guide and interviews use.
- Ground the microarchitecture in the TPU paper (tiled/weight-stationary matmul) and the
  FlashAttention paper (online softmax). Follow docs/uarch.md as source of truth.
- BIT-ACCURACY RULE (P1's #1 failure mode): before writing any datapath RTL, ensure the
  golden model in model/ is bit-accurate to the intended hardware: same Q-format, same
  exp approximation (the SAME LUT the RTL will use, emitted by the model), same rounding
  and saturation. RTL that is compared against a float-exp model will never match. If the
  model is not bit-accurate yet, that is a Phase-0 blocker; fix it before RTL.
- Do NOT attempt OpenLane/Sky130 during Phases 0-5. Physical design is Phase 7 and is
  installed and run separately so its heavy Docker toolchain never blocks core work.
- After writing, run `make verify-fw MODULE=<name>` (or the project's verify target)
  and paste the full command and its exit code. Do not hand off until it exits 0.
- Never claim a step passed without pasting its output. Never edit EVIDENCE.md by hand.
Hand off to the auditors only when verify exits 0.
EOF
fi

if [ ! -f .claude/agents/verification-engineer.md ]; then
cat > .claude/agents/verification-engineer.md << 'EOF'
---
name: verification-engineer
description: Writes the cocotb testbench, the functional coverage model, and the SVA properties for a module. Use alongside the rtl-designer.
tools: Read, Write, Edit, Bash, Grep, Glob
model: sonnet
---
You build the verification collateral for the attention engine (cocotb TB, coverage
model, SVA), not the design. Check RTL against model/attn.py and model/attn.cpp golden
models. Softmax invariants to assert: running-max monotonic within a tile, rescale
correctness, accumulator never overflows its declared width.
- OPEN-TOOL FORMAL LIMIT (real constraint): SymbiYosys via yosys supports only a SUBSET
  of SVA. Keep formal properties SIMPLE and yosys-parseable: prefer immediate assertions
  and simple concurrent assertions; avoid rich sequences, multi-clock properties, and
  heavy $past chains that the open flow cannot prove. Scope formal to a few core
  invariants (accumulator-no-overflow, running-max-monotonic) and put all rich behavioral
  checking in cocotb, not formal. If a property will not parse in sby, move it to cocotb
  rather than fighting the tool.
- Self-checking testbenches: assert on expected values, fail loudly. No eyeball-the-waveform passes.
- Define a coverage model before "done": a bin for every mode, corner, and error condition.
- Write SVA for every documented invariant and critical path; keep them provable by sby where feasible.
- Use a fixed seed and record it. Run the sim and coverage targets and paste the results with exit codes.
- You may not weaken a check to make it pass. A failing check is a finding for the designer.
EOF
fi

# ---------------------------------------------------------------------------
# TEAM BETA (red team, READ-ONLY: no Edit/Write; they re-run and report)
# ---------------------------------------------------------------------------

if [ ! -f .claude/agents/lint-synth-auditor.md ]; then
cat > .claude/agents/lint-synth-auditor.md << 'EOF'
---
name: lint-synth-auditor
description: Read-only physical auditor. Re-runs lint and synth-check on a module, hunts inferred latches, non-synthesizable constructs, and timing problems. Use to review a module the builders marked ready.
tools: Read, Bash, Grep, Glob
model: sonnet
---
You are adversarial and read-only by design: you report, you do not fix.
- Re-run `make lint` and `make synth-check` yourself in this clean context. Paste output.
- Read the raw synth log. Look for: inferred latches ($_DLATCH_), non-synthesizable
  constructs, multi-driver nets, unintended priority logic, and timing/Fmax regressions.
- Check the module against CLAUDE.md's coding standards line by line.
- Countersign only by referencing the EVIDENCE.md row. If synth-check did not exit 0,
  refuse to sign and list every failing item.
EOF
fi

if [ ! -f .claude/agents/formal-coverage-auditor.md ]; then
cat > .claude/agents/formal-coverage-auditor.md << 'EOF'
---
name: formal-coverage-auditor
description: Read-only functional auditor. Re-runs sim, coverage, and formal in a clean context, attacks coverage holes and corner cases, reads sby counterexamples. Use to review a module the builders marked ready.
tools: Read, Bash, Grep, Glob
model: opus
---
You are adversarial and read-only by design: you report, you do not fix.
- Re-run `make sim`, `make coverage`, and `make formal` yourself. Paste output.
- Assume the module is broken. Propose specific breaking cases (min/max, back-to-back,
  reset mid-transaction, overflow/underflow, wrap, X-propagation, clock-ratio extremes).
  If any is untested or uncovered, that is a finding.
- On a failing assertion, read the sby counterexample trace and describe the exact
  sequence that breaks the property; do not hand-wave it.
- Countersign only by referencing the EVIDENCE.md row. If any check did not exit 0,
  refuse to sign and list every failing property or coverage hole.
EOF
fi

# ---------------------------------------------------------------------------
# TECHNICAL WRITER (see process/technical-writer.md contract for the full rules)
# ---------------------------------------------------------------------------

if [ ! -f .claude/agents/technical-writer.md ]; then
cat > .claude/agents/technical-writer.md << 'EOF'
---
name: technical-writer
description: Produces docs/guide.md at reference-guide depth, from repo artifacts and EVIDENCE.md only. Use after modules pass verify or at a milestone.
tools: Read, Bash, Grep, Glob
model: opus
---
You have TWO modes.

MODE A (default, during/after build): produce docs/guide.md per the full contract in
process/technical-writer.md and graded against process/asic-guide-fidelity-rubric.md. In this mode you
DOCUMENT the finished result; you do not tutor. Core rules:
- Paste code verbatim from repo files; never retype it.
- Every number is a shown derivation or a value read from a named report, cross-checked
  against the RTL parameter. A mismatch is a blocking error.
- Every claim maps to an EVIDENCE.md row: PASS states plainly, PENDING-HARDWARE uses the
  honest interim voice ("verified in simulation and formal; synthesized to a latch-free
  netlist meeting timing at <Fmax from report>; not implemented on FPGA / not taped out").
- Resume bullets only stage-gated, with the clause-to-evidence table.
- No em dashes.
Finish by running `make audit-guide` and reporting its exit code. If it fails, fix the
offending claims (add evidence or move to interim voice); do not weaken the audit.

MODE B (REPLICATION TUTOR, only after `make verify` is green for a module and the user
types "tutor me on <module>"): you switch from documenter to teacher. Rules for Mode B:
- You may NOT run in Mode B while a module is still being built. Guard: refuse if the
  module has no VERIFY OK row in EVIDENCE.md.
- Drive the user to rebuild the module FROM A BLANK FILE. Tell them to not open the
  finished rtl/ file. You work from docs/guide.md + the paper, revealing nothing verbatim.
- One concept at a time, Socratic: ask why this width, why this reset style, why gray/
  fixed-point choice, what breaks without it. Make them derive numbers themselves.
- Hint ladder only (concept -> location -> words). Never show the finished line.
- Grill mode: after they rebuild a block, ask hostile interview questions until they
  fail, then explain the strong answer. Sign off only when they can defend every line.
- You are teaching, not editing: no Write/Edit in Mode B.
EOF
fi

# make the writer also reachable as a slash-skill: /write-guide
if [ ! -f .claude/skills/write-guide/SKILL.md ]; then
cat > .claude/skills/write-guide/SKILL.md << 'EOF'
---
name: write-guide
description: Generate or refresh docs/guide.md from artifacts and EVIDENCE.md, at reference-guide depth.
---
Delegate to the technical-writer subagent. Regenerate docs/guide.md following the contract in
process/technical-writer.md and the rubric in process/asic-guide-fidelity-rubric.md. Do not invent numbers
or bench results. End by running `make audit-guide` and report the exit code.
EOF
fi

# ---------------------------------------------------------------------------
# HOOKS: lint on every RTL edit, and block "Done" without a passing verify
# ---------------------------------------------------------------------------

if [ ! -f .claude/settings.json ]; then
cat > .claude/settings.json << 'EOF'
{
  "statusLine": {
    "type": "command",
    "command": "bash $CLAUDE_PROJECT_DIR/scripts/progress_status.sh"
  },
  "hooks": {
    "PostToolUse": [
      { "matcher": "Edit|Write",
        "hooks": [ { "type": "command",
          "command": "bash $CLAUDE_PROJECT_DIR/.claude/hooks/lint_on_edit.sh" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command",
          "command": "bash $CLAUDE_PROJECT_DIR/.claude/hooks/verify_gate.sh" } ] }
    ]
  }
}
EOF
fi

if [ ! -f .claude/hooks/lint_on_edit.sh ]; then
cat > .claude/hooks/lint_on_edit.sh << 'EOF'
#!/usr/bin/env bash
# PostToolUse hook (Edit|Write): lint an edited .sv/.v file with verilator.
# WARNS during development; hard-blocks (exit 2) only for files listed in
# .ready_for_lint (repo-relative paths, one per line).
#
# Rewritten 2026-09-18 (review finding H4). The original (1) compared the
# ABSOLUTE tool_input.file_path against the RELATIVE entries of
# .ready_for_lint, so the hard-block never fired; (2) linted the single file
# alone, so online_softmax.sv (`include "rtl/exp_lut.svh"), matmul_tile.sv
# and attention_top.sv (submodules) always errored regardless of content.
# Now: path is made repo-relative, the whole rtl/ set (plus the edited
# file's own directory, e.g. fpga/) is elaborated with the repo root as the
# include dir and the edited module as top.
set -u
root=${CLAUDE_PROJECT_DIR:-$(pwd)}
cd "$root" || exit 0

abs=$(jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
case "$abs" in
  *.sv|*.v) ;;
  *) exit 0 ;;
esac
command -v verilator >/dev/null 2>&1 || exit 0

rel=$(realpath --relative-to="$root" "$abs" 2>/dev/null || printf '%s' "$abs")
rel=${rel#./}
mod=$(basename "$rel"); mod=${mod%.*}
dir=$(dirname "$rel")

srcs=(rtl/*.sv)
if [ "$dir" != "rtl" ]; then srcs+=("$dir"/*.sv); fi

err=$(mktemp); trap 'rm -f "$err"' EXIT
if ! verilator --lint-only -Wall -sv +incdir+. --top-module "$mod" "${srcs[@]}" 2>"$err"; then
  if [ -f .ready_for_lint ] && grep -Fxq -- "$rel" .ready_for_lint; then
    echo "Lint failed on READY file $rel:" >&2; sed 's/^/  /' "$err" >&2; exit 2
  fi
  echo "Lint warnings on $rel (dev mode, not blocking):" >&2; sed 's/^/  /' "$err" >&2
fi
exit 0
EOF
chmod +x .claude/hooks/lint_on_edit.sh
fi

if [ ! -f .claude/hooks/verify_gate.sh ]; then
cat > .claude/hooks/verify_gate.sh << 'EOF'
#!/usr/bin/env bash
# Stop hook: block ending a session with a module marked [Done] in PLAN.md
# that has no "VERIFY OK: <module>" line in EVIDENCE.md.
#
# Rewritten 2026-09-18 (review finding H3). The original had two defects that
# made it a no-op: (1) `exit 2` ran inside a `while read` fed by a pipe, i.e.
# in a subshell, so the outer script always exited 0; (2) the regex captured
# only "rtl" from "[Done] rtl/mac_unit.sv" while EVIDENCE rows read
# "VERIFY OK: mac_unit". The loop now runs in the main shell (process
# substitution) and the module name is the path basename without extension.
set -u
root=${CLAUDE_PROJECT_DIR:-$(pwd)}
cd "$root" || exit 2
[ -f PLAN.md ] || exit 0

status=0
while IFS= read -r mod; do
  [ -n "$mod" ] || continue
  if ! grep -Fxq -- "VERIFY OK: $mod" EVIDENCE.md 2>/dev/null; then
    echo "Task '$mod' is marked [Done] in PLAN.md but has no 'VERIFY OK: $mod' row in EVIDENCE.md." >&2
    status=2
  fi
done < <(sed -nE 's|.*\[Done\][[:space:]]+([A-Za-z0-9_./-]+).*|\1|p' PLAN.md \
         | sed -E 's|^.*/||; s|\.[A-Za-z0-9]+$||')
exit $status
EOF
chmod +x .claude/hooks/verify_gate.sh
fi

# ---------------------------------------------------------------------------
# PLAN.md and EVIDENCE.md (the Lead's worklist and the ledger)
# ---------------------------------------------------------------------------

# scripts/check_coverage.py is a tracked file with its own history; the scaffold
# no longer embeds a copy (the embedded one was the superseded pooled version).
mkdir -p scripts

if [ ! -f PLAN.md ]; then
cat > PLAN.md << 'EOF'
# PLAN

Task format:  [Status] <module>  (domain: sandbox|hardware)  owner: <agent>
Status is one of: [Todo] [Building] [Ready] [Done] [Blocked: needs bench]
Only Lead moves a task to [Done], and only after make verify exits 0, an EVIDENCE row
exists, and a Beta auditor has countersigned.

## Phase -1 — PROVE THE TOOLCHAIN (do this before any P1 module)
- [Todo] tool_smoke  (domain: sandbox)  owner: rtl-designer
  A throwaway 2-line module (a resettable counter) taken all the way through
  lint -> sim -> coverage(STUB) -> synth-check -> formal. Do NOT start mac_unit until
  `make verify MODULE=tool_smoke COVERAGE_STUB=1` exits 0. This proves verilator,
  verible, iverilog/cocotb, yosys, and sby+solver are actually installed and wired.

## Backlog
- [Todo] mac_unit  (domain: sandbox)  owner: rtl-designer
- [Todo] mac_unit_tb  (domain: sandbox)  owner: verification-engineer

## Hardware (cannot reach Done in sandbox; stay Blocked until bench evidence)
- [Blocked: needs bench] fpga_bringup  (domain: hardware)
- [Blocked: needs bench] tinytapeout_silicon  (domain: hardware)
EOF
fi

if [ ! -f EVIDENCE.md ]; then
cat > EVIDENCE.md << 'EOF'
# EVIDENCE ledger

The verify targets append rows here. The technical-writer reads this and may only make
claims backed by a PASS row. Hardware/silicon claims stay PENDING-HARDWARE until you add
a row with real bench evidence.

| id | claim | status | command / artifact | exit |
|----|-------|--------|--------------------|------|
EOF
fi

# ---------------------------------------------------------------------------
# Minimal Makefile ONLY if you do not already have one (yours wins)
# ---------------------------------------------------------------------------

if [ ! -f Makefile ]; then
cat > Makefile << 'EOF'
MODULE ?= mac_unit
SEED   ?= 1
SRC    := rtl/$(MODULE).sv

lint:
	verilator --lint-only -Wall -sv $(SRC)
	verible-verilog-lint $(SRC)

sim:
	$(MAKE) -C tb/$(MODULE) SIM=verilator SEED=$(SEED)

coverage:
	python3 scripts/check_coverage.py --line 90 --func 100

synth-check:
	yosys -p 'read_verilog -sv $(SRC); hierarchy -top $(MODULE); proc; opt; check -assert' 2>&1 | tee build/synth.log
	@! grep -q '\$$_DLATCH_' build/synth.log || (echo "INFERRED LATCH" && false)

formal:
	sby -f formal/$(MODULE).sby

verify-fw verify: lint sim coverage synth-check formal
	@mkdir -p build
	@echo "| verify-$(MODULE) | $(MODULE) passes lint/sim/cov/synth/formal | PASS | make verify MODULE=$(MODULE) | 0 |" >> EVIDENCE.md
	@echo "VERIFY OK: $(MODULE)" | tee -a EVIDENCE.md

audit-guide:
	@test -f docs/guide.md || (echo "no docs/guide.md yet" && exit 1)
	@if grep -niE 'taped out|on the (real )?board|runs on the fpga|measured on|soldered|powered on' docs/guide.md \
	   | grep -viE 'pending|not (yet )?(implemented|taped|fabricated)|in simulation|renode' ; then \
	   echo "audit-guide: unbacked hardware/silicon claim found"; exit 1; \
	 else echo "audit-guide: clean"; fi
EOF
mkdir -p build rtl tb formal scripts
fi

echo ""
echo "Done. Created:"
echo "  .claude/agents/{rtl-designer,verification-engineer,lint-synth-auditor,formal-coverage-auditor,technical-writer}.md"
echo "  .claude/skills/write-guide/SKILL.md"
echo "  .claude/settings.json + .claude/hooks/{lint_on_edit,verify_gate}.sh"
echo "  PLAN.md, EVIDENCE.md  (and a minimal Makefile if you had none)"
echo ""
echo "Next: make sure CLAUDE.md, process/technical-writer.md, and process/asic-guide-fidelity-rubric.md"
echo "are in the repo root, edit PLAN.md's <first_module>, then run:  claude"
