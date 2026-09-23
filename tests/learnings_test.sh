#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/tower-fixtures.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
new_repo "$TMP/project"
new_project "$TMP/project"
new_card "$TMP/project" T001 Makefile
cat > "$TMP/project/.tower/learnings.md" <<'EOF'
## Always
- [process] Run verification (T001)
## scope: Makefile
- [tooling] Preserve tabs (T001)
## scope: src/shared/**
- [process] Shared code needs review (T002)
EOF
OUT="$(cd "$TMP/project" && "$ROOT/bin/tower-learnings" --for T001)"
assert_true 'extensionless owned file selects its lessons' grep -q 'Preserve tabs' <<< "$OUT"
assert_true 'always lessons remain selected' grep -q 'Run verification' <<< "$OUT"
new_card "$TMP/project" T002 'src/shared-other/file.sh'
OUT="$(cd "$TMP/project" && "$ROOT/bin/tower-learnings" --for T002)"
assert_false 'sibling directory does not select scoped lesson' grep -q 'Shared code' <<< "$OUT"

cp "$TMP/project/.tower/tasks/T001-test.md" "$TMP/project/.tower/tasks/T001-other.md"
(cd "$TMP/project" && "$ROOT/bin/tower-learnings" --for T001) > "$TMP/ambiguous.out" 2>&1
assert_status 'ambiguous card id refuses to guess which lessons apply' "$?" 1
assert_true 'ambiguous learnings names every matching file' grep -q 'T001-other.md' "$TMP/ambiguous.out"
rm "$TMP/project/.tower/tasks/T001-other.md"

cat > "$TMP/project/.tower/learnings.md" <<'EOF'
## Always
- [process] a wrapped entry whose provenance sits on the
  continuation line (T004)
- [process] an unwrapped entry with provenance (T001)
- [process] a wrapped entry with no provenance
  anywhere in its text
EOF
OUT="$(cd "$TMP/project" && "$ROOT/bin/tower-learnings" --check)"
assert_true 'entries total counts bullets, not continuation lines' grep -q '^entries: 3 / ' <<< "$OUT"
assert_true 'only the entry without provenance is counted as missing it' grep -q '^no (T###) provenance: 1 ' <<< "$OUT"
assert_true 'missing provenance is reported at the entry first line' grep -qx '5:- \[process\] a wrapped entry with no provenance' <<< "$OUT"
assert_false 'provenance on a continuation line is read' grep -q '^2:' <<< "$OUT"
assert_false 'unwrapped entry with provenance is not reported' grep -q '^4:' <<< "$OUT"

summary
