#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/tower-fixtures.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fixture() {
  PROJECT="$TMP/$1"
  new_repo "$PROJECT"
  new_project "$PROJECT"
}

doctor() {
  "$ROOT/bin/tower-doctor" --from "$PROJECT" > "$TMP/doctor.out" 2>&1
}

has_finding() { grep -q "\[$1\]" "$TMP/doctor.out"; }

set_field() {
  local key="$1" value="$2"
  awk -v key="$key" -v value="$value" '
    index($0,key ":")==1 {$0=key ": " value}
    {print}
  ' "$PROJECT/.tower/tasks/T001-test.md" > "$TMP/card"
  mv "$TMP/card" "$PROJECT/.tower/tasks/T001-test.md"
}

fixture healthy
new_card "$PROJECT" T001
assert_true 'ready project has no recovery findings' doctor
assert_true 'healthy output is explicit' grep -q 'no issues found' "$TMP/doctor.out"
dispatch "$PROJECT" T001 --prep
assert_true 'healthy in-flight task is not assumed stuck' doctor
WT="$(git -C "$PROJECT" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
assert_true 'doctor resolves from a linked worktree' "$ROOT/bin/tower-doctor" --from "$WT"

fixture lock
mkdir "$PROJECT/.tower/.git/tower-dispatch.lock"
assert_false 'existing lock requires attention' doctor
assert_true 'lock is reported' has_finding dispatch-lock
assert_true 'lock uncertainty is explicit' grep -q 'cannot determine whether it is stale' "$TMP/doctor.out"
assert_true 'lock recovery names rmdir' grep -q rmdir "$TMP/doctor.out"
assert_true 'doctor does not remove lock' test -d "$PROJECT/.tower/.git/tower-dispatch.lock"

fixture blocked
new_card "$PROJECT" T001
set_field status blocked
assert_false 'blocked task requires attention' doctor
assert_true 'blocked card is reported' has_finding blocked
assert_true 'missing blocked handoff is reported' has_finding missing-handoff

fixture missing-branch
new_card "$PROJECT" T001
set_field status in-flight
assert_false 'in-flight card must identify its branch' doctor
assert_true 'missing branch field is reported' has_finding missing-branch
set_field branch tower/missing/T001
doctor
assert_true 'deleted branch is distinguished' has_finding unknown-branch

fixture missing-worktree
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
WT="$(git -C "$PROJECT" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
rm "$WT/.tower" "$WT/.tower-task"
git -C "$PROJECT" worktree remove "$WT"
assert_false 'active branch without a checkout requires recovery' doctor
assert_true 'missing worktree is reported' has_finding missing-worktree
assert_true 'recovery names the recorded branch' grep -q 'tower/root/T001-test' "$TMP/doctor.out"

fixture mismatches
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
WT="$(git -C "$PROJECT" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
rm "$WT/.tower"
mkdir "$WT/.tower"
echo T999 > "$WT/.tower-task"
assert_false 'wrong shared state requires recovery' doctor
assert_true 'wrong state directory is reported' has_finding state-mismatch
assert_true 'wrong task marker is reported' has_finding task-marker

fixture review
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
set_field status in-review
assert_false 'review needs PR and draft handoff' doctor
assert_true 'missing review PR is reported' has_finding missing-pr
assert_true 'missing draft is reported' has_finding missing-handoff
set_field pr '"42"'
echo draft > "$PROJECT/.tower/handoffs/T001-handoff.md"
assert_true 'complete in-review state is healthy' doctor

fixture merged
new_card "$PROJECT" T001
set_field status merged
set_field pr '"42"'
assert_false 'merged card needs handoff' doctor
assert_true 'missing final handoff is reported' has_finding missing-handoff
echo final > "$PROJECT/.tower/handoffs/T001-handoff.md"
assert_false 'unprocessed handoff requires attention' doctor
assert_true 'missing receipt is reported' has_finding pending-ingest
HASH="$(git hash-object "$PROJECT/.tower/handoffs/T001-handoff.md")"
awk -v hash="$HASH" '{print} /^pr:/ {print "ingested_handoff: " hash}' \
  "$PROJECT/.tower/tasks/T001-test.md" > "$TMP/card"
mv "$TMP/card" "$PROJECT/.tower/tasks/T001-test.md"
assert_true 'processed merged card needs no surviving worktree' doctor
echo corrected >> "$PROJECT/.tower/handoffs/T001-handoff.md"
assert_false 'changed handoff requires another ingest' doctor
assert_true 'changed content invalidates receipt' has_finding pending-ingest

git -C "$PROJECT/.tower" add .
git -C "$PROJECT/.tower" commit -q -m 'tower: fixture'
echo staged > "$PROJECT/.tower/design.md"
git -C "$PROJECT/.tower" add design.md
BEFORE="$(git -C "$PROJECT/.tower" rev-parse HEAD) $(git hash-object "$PROJECT/.tower/.git/index") $(git hash-object "$PROJECT/.tower/tasks/T001-test.md") $(git hash-object "$PROJECT/.tower/handoffs/T001-handoff.md")"
doctor
AFTER="$(git -C "$PROJECT/.tower" rev-parse HEAD) $(git hash-object "$PROJECT/.tower/.git/index") $(git hash-object "$PROJECT/.tower/tasks/T001-test.md") $(git hash-object "$PROJECT/.tower/handoffs/T001-handoff.md")"
assert_eq 'diagnosis preserves commit, index, card and handoff bytes' "$AFTER" "$BEFORE"

"$ROOT/bin/tower-doctor" --from "$TMP" > "$TMP/doctor.out" 2>&1
assert_status 'unresolved project preserves locator exit code' "$?" 3

fixture invalid
new_card "$PROJECT" T001
set_field status unknown
assert_false 'unknown card status is diagnosed' doctor
assert_true 'invalid card finding is readable' has_finding invalid-card
set_field id ../T001
doctor
assert_true 'invalid ID cannot escape handoff directory' has_finding invalid-card

fixture missing-link
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
WT="$(git -C "$PROJECT" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
rm "$WT/.tower"
assert_false 'missing state link requires attention' doctor
assert_true 'missing state link is distinguished from conflicting state' has_finding missing-state
assert_true 'missing link recovery uses ln without deleting files' grep -q 'ln -s' "$TMP/doctor.out"
mv "$WT" "$WT-moved"
doctor
assert_true 'missing registered directory is diagnosed' has_finding missing-checkout
new_repo "$WT"
doctor
assert_true 'replacement repository is diagnosed' has_finding foreign-checkout

fixture inplace
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep --in-place
assert_true 'in-place task needs no worktree marker' doctor

PROJECT="$TMP/tracked"
new_repo "$PROJECT"
"$ROOT/bin/tower-init" "$PROJECT" > /dev/null
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep --in-place
assert_true 'tracked state supports healthy in-place diagnosis' doctor

fixture 'monorepo'
mkdir -p "$PROJECT/services/api"
new_project "$PROJECT/services/api"
PROJECT="$PROJECT/services/api"
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
assert_true 'monorepo paths resolve inside the task worktree' doctor

fixture "quote's-project"
new_card "$PROJECT" T001
dispatch "$PROJECT" T001 --prep
assert_true 'quoted project paths remain healthy' doctor

env TOWER_PROJECT_DIR="$TMP/missing" "$ROOT/bin/tower-doctor" --from "$PROJECT" > "$TMP/doctor.out" 2>&1
assert_status 'explicit project overrides stale environment' "$?" 0
(cd "$TMP/healthy" && "$ROOT/bin/tower-doctor") > "$TMP/doctor.out" 2>&1
assert_status 'no-argument invocation uses the current project' "$?" 0

PROJECT="$TMP/ambiguous"
new_repo "$PROJECT"
mkdir "$PROJECT/one" "$PROJECT/two"
new_project "$PROJECT/one"
new_project "$PROJECT/two"
doctor
assert_status 'ambiguous discovery retains locator exit code' "$?" 4

PROJECT="$TMP/copy"
new_repo "$PROJECT"
"$ROOT/bin/tower-init" "$PROJECT" > /dev/null
git -C "$PROJECT" worktree add -q -b task "$TMP/copy-worktree"
rm -rf "$PROJECT/.tower"
PROJECT="$TMP/copy-worktree"
assert_false 'per-branch state copy is rejected' doctor
assert_true 'noncanonical copy has a distinct finding' has_finding state-copy

summary
