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
sed -i '' -e 's/status: ready/status: in-review/' -e 's/pr: ""/pr: "42"/' "$PROJECT/.tower/tasks/T001-test.md"
git -C "$PROJECT/.tower" add .
git -C "$PROJECT/.tower" commit -q -m 'tower: review'
BEFORE="$(git -C "$PROJECT/.tower" rev-parse HEAD)"
mkdir "$TMP/fakebin"
printf '#!/usr/bin/env bash\necho MERGED\n' > "$TMP/fakebin/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/fakebin/osascript"
printf '#!/usr/bin/env bash\nexit 23\n' > "$TMP/fakebin/sleep"
chmod +x "$TMP/fakebin/"*
export PATH="$TMP/fakebin:$PATH"

watch_once() {
  (cd "$PROJECT" && "$ROOT/bin/tower-watch" --interval 1 --on-merge 'printf "%s %s" "$TOWER_TASK" "$TOWER_PR" > callback.txt') > "$TMP/watch.out" 2>&1
}

watch_once
assert_eq 'PR merge alone does not finalize task' "$(card_field "$PROJECT" T001 status)" in-review
assert_eq 'watcher never commits incomplete handoff state' "$(git -C "$PROJECT/.tower" rev-parse HEAD)" "$BEFORE"
assert_eq 'merge callback receives task and PR' "$(cat "$PROJECT/callback.txt")" 'T001 42'
echo draft > "$PROJECT/.tower/handoffs/T001-handoff.md"
watch_once
assert_eq 'draft handoff does not authorize merged status' "$(card_field "$PROJECT" T001 status)" in-review
assert_eq 'draft remains untouched' "$(cat "$PROJECT/.tower/handoffs/T001-handoff.md")" draft
summary
