# evidence/: tracked copies of the reports EVIDENCE.md cites

EVIDENCE.md rows for synthesis, STA, GLS, power and the auditor re-runs
cite files under build/, which is gitignored, so until 2026-09-18 none of
the quoted numbers (slack, cell counts, toggle totals, mW) could be
inspected from a clone (review finding F014).

`make evidence-snapshot` (scripts/evidence_snapshot.py) copies the text
reports from build/ into reports/<UTC stamp>/ together with MANIFEST.txt
(git commit, tool versions, sha256 and size per file). Commit that
directory and cite `evidence/reports/<stamp>/<file>` from the row that
quotes it.

No snapshot exists yet for the rows written before this mechanism existed:
the historical build/ artifacts were never committed and the flow has not
been re-run since. Those rows remain as written; the errata rows at the end
of EVIDENCE.md say which numbers are regenerable and which are not.
