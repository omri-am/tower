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
summary
