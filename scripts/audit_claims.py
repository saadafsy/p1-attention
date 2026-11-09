#!/usr/bin/env python3
"""Hardware/silicon claim audit for the claim documents (make audit-guide).

A prohibited verb passes only if its own clause carries an interim qualifier,
a negation or a conditional framing. The phase 6/7 manuals are checked only
for their PENDING banner. Exit 1 on any unqualified claim (file:line, clause).
"""
import re
import sys
from pathlib import Path

CLAIM_DOCS = [
    "docs/guide.md", "README.md", "docs/uarch.md", "docs/benchmark.md",
    "docs/tradeoffs.md", "docs/verification_plan.md",
]
MANUALS = {
    "docs/phase6_fpga_guide.md": "NOTHING IN THIS DOCUMENT HAS BEEN EXECUTED",
    "docs/phase7_physical_guide.md": "NOTHING IN THIS DOCUMENT HAS BEEN EXECUTED",
}

PROHIBITED = re.compile(
    r"\b(taped[ -]out|tape[ -]out|fabricated|on the (real )?board|runs? on the fpga|"
    r"running on (the )?(fpga|hardware|silicon)|measured on (the )?(board|hardware|silicon)|"
    r"bring[ -]up (succeeded|complete|passed)|soldered|powered on|"
    r"on silicon|silicon[- ]proven|bench[- ]measured)\b",
    re.IGNORECASE,
)
# A sentence may contain a prohibited verb only with one of these framings.
ALLOWED = re.compile(
    r"\b(pending|pending-hardware|not (yet )?(implemented|taped|fabricated|measured|run|executed)|"
    r"nothing (is )?(implemented|fabricated|taped)|never|cannot|can never|must not|may not|"
    r"until|would|requires?|needs?|if |when |once |before |plan|future|interim|"
    r"no (fpga|hardware|silicon|bench|measured)|none is claimed|not claimed|stays? |remains?|"
    r"in simulation|simulated|tool estimate|no rows)\b",
    re.IGNORECASE,
)

def sentences(text):
    """Yield (first_lineno, clause): paragraphs split into sentences, then clauses at ';' and ' -- '."""
    para, start = [], None
    def flush():
        if para:
            joined = " ".join(para)
            for sent in re.split(r"(?<=[.!?])\s+(?=[A-Z\"'(\[])", joined):
                for clause in re.split(r";|\s--\s", sent):
                    if clause.strip():
                        yield start, clause.strip()
    for lineno, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        boundary = (not s) or s.startswith(("#", "|", "- ", "* ", "```", ">")) or re.match(r"^\d+\.\s", s)
        if boundary:
            yield from flush()
            para, start = ([s] if s else []), (lineno if s else None)
        else:
            if not para:
                start = lineno
            para.append(s)
    yield from flush()

def main():
    bad = 0
    for rel in CLAIM_DOCS:
        p = Path(rel)
        if not p.is_file():
            print(f"audit-guide: {rel} missing (skipped)")
            continue
        for lineno, sent in sentences(p.read_text(encoding="utf-8", errors="replace")):
            if PROHIBITED.search(sent) and not ALLOWED.search(sent):
                bad += 1
                print(f"{rel}:{lineno}: unqualified hardware/silicon claim: {sent}")
    for rel, banner in MANUALS.items():
        p = Path(rel)
        if p.is_file() and banner not in p.read_text(encoding="utf-8", errors="replace"):
            bad += 1
            print(f"{rel}: missing the PENDING banner '{banner}'")
    if bad:
        print(f"audit-guide: {bad} unbacked hardware/silicon claim(s) found")
        return 1
    print("audit-guide: clean")
    return 0

if __name__ == "__main__":
    sys.exit(main())
