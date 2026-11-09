# evidence/: tracked copies of the reports EVIDENCE.md cites

`make evidence-snapshot` (scripts/evidence_snapshot.py) copies the text
reports from build/ (gitignored) into reports/<UTC stamp>/ with MANIFEST.txt
(git commit, tool versions, sha256 and size per file). Commit that directory
and cite `evidence/reports/<stamp>/<file>` from the row that quotes it.

Rows written before this mechanism have no snapshot; the errata rows at the
end of EVIDENCE.md say which of their numbers are regenerable.
