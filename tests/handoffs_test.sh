#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/tower-fixtures.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PROJECT="$TMP/project"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
new_card "$PROJECT" T002
sed -i '' 's/status: ready/status: merged/' "$PROJECT/.tower/tasks/T001-test.md"
echo final > "$PROJECT/.tower/handoffs/T001-handoff.md"
echo draft > "$PROJECT/.tower/handoffs/T002-handoff.md"
git -C "$PROJECT/.tower" add .
git -C "$PROJECT/.tower" commit -q -m 'tower: T001 finalized'
git -C "$PROJECT/.tower" commit -q --allow-empty -m 'tower: unrelated dispatch'

pending() { (cd "$PROJECT" && "$ROOT/bin/tower-handoffs"); }
OUT="$(pending)"
assert_status 'pending handoffs can be read' "$?" 0
assert_eq 'unrelated commit cannot hide unprocessed handoff' "$OUT" T001
HASH="$(git hash-object "$PROJECT/.tower/handoffs/T001-handoff.md")"
awk -v hash="$HASH" '{print} /^pr:/ {print "ingested_handoff: \"" hash "\""}' \
  "$PROJECT/.tower/tasks/T001-test.md" > "$TMP/card"
mv "$TMP/card" "$PROJECT/.tower/tasks/T001-test.md"
assert_empty 'matching receipt hides processed handoff' "$(pending)"
echo corrected >> "$PROJECT/.tower/handoffs/T001-handoff.md"
assert_eq 'corrected handoff requires another ingest' "$(pending)" T001
rm "$PROJECT/.tower/handoffs/T001-handoff.md"
pending > "$TMP/pending.out" 2> "$TMP/pending.err"
assert_status 'merged task with missing handoff is an error' "$?" 1
assert_true 'missing handoff error names task' grep -q T001 "$TMP/pending.err"
summary
