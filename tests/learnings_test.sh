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

cat > "$TMP/project/.tower/learnings.md" <<'EOF'
# Learnings
> Format notes
  orphan indentation

- [process] First flat lesson (T001)
- [testing] Wrapped lesson
  with provenance (T002)
  and another continuation

  detached indentation
> Trailing notes
EOF
cat > "$TMP/flat.expected" <<'EOF'
<!-- learnings selected for T001 from learnings.md -->
## Unsectioned (before the first heading)
- [process] First flat lesson (T001)
- [testing] Wrapped lesson
  with provenance (T002)
  and another continuation
EOF
(cd "$TMP/project" && "$ROOT/bin/tower-learnings" --for T001) > "$TMP/flat.out"
assert_true 'flat file selects complete entries without preamble or detached lines' cmp -s "$TMP/flat.expected" "$TMP/flat.out"

cat >> "$TMP/project/.tower/learnings.md" <<'EOF'
## scope: Makefile
- [tooling] Preserve tabs (T001)
## Always
- [process] Run verification (T001)
EOF
cp "$TMP/flat.expected" "$TMP/mixed.expected"
cat >> "$TMP/mixed.expected" <<'EOF'
## scope: Makefile
- [tooling] Preserve tabs (T001)
## Always
- [process] Run verification (T001)
EOF
(cd "$TMP/project" && "$ROOT/bin/tower-learnings" --for T001) > "$TMP/mixed.out"
assert_true 'unsectioned entries precede matching and unscoped sections' cmp -s "$TMP/mixed.expected" "$TMP/mixed.out"
sed 's/selected for T001/selected for T002/' "$TMP/flat.expected" > "$TMP/other.expected"
cat >> "$TMP/other.expected" <<'EOF'
## Always
- [process] Run verification (T001)
EOF
(cd "$TMP/project" && "$ROOT/bin/tower-learnings" --for T002) > "$TMP/other.out"
assert_true 'unsectioned entries are selected for unrelated ownership too' cmp -s "$TMP/other.expected" "$TMP/other.out"

cat > "$TMP/check.expected" <<'EOF'
entries: 4 / budget 60
retired: 0 in learnings-archive.md
unsectioned: 2 entries before the first ## heading - included in every prompt
EOF
(cd "$TMP/project" && TOWER_LEARNINGS_BUDGET=60 "$ROOT/bin/tower-learnings" --check) > "$TMP/check.out"
CHECK_STATUS=$?
assert_eq 'check reports unsectioned count without changing total or success status' \
  "$CHECK_STATUS:$(cat "$TMP/check.out")" "0:$(cat "$TMP/check.expected")"
sed 's/budget 60/budget 3/' "$TMP/check.expected" > "$TMP/over-budget.expected"
(cd "$TMP/project" && TOWER_LEARNINGS_BUDGET=3 "$ROOT/bin/tower-learnings" --check) > "$TMP/over-budget.out" 2> "$TMP/over-budget.err"
CHECK_STATUS=$?
assert_eq 'unsectioned count remains informational when already over budget' \
  "$CHECK_STATUS:$(cat "$TMP/over-budget.out")" "1:$(cat "$TMP/over-budget.expected")"

summary
