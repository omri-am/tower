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
new_repo "$TMP/foreign"
assert_false 'foreign repository rejected' dispatch "$PROJECT" T001 --prep --worktree "$TMP/foreign"
assert_eq 'rejection preserves ready status' "$(card_field "$PROJECT" T001 status)" ready
assert_false 'rejection creates no foreign task marker' test -e "$TMP/foreign/.tower-task"

PROJECT="$TMP/canonical"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
assert_false 'main checkout cannot be adopted as a worktree' dispatch "$PROJECT" T001 --prep --worktree "$PROJECT"

PROJECT="$TMP/adopt"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
git -C "$PROJECT" worktree add -q -b feature "$TMP/adopted"
assert_true 'related worktree accepted' dispatch "$PROJECT" T001 --prep --worktree "$TMP/adopted"
assert_eq 'adoption records actual branch' "$(card_field "$PROJECT" T001 branch)" feature
assert_eq 'adoption links canonical state' "$(cd "$TMP/adopted/.tower" && pwd -P)" "$(cd "$PROJECT/.tower" && pwd -P)"

PROJECT="$TMP/wrong-state"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
git -C "$PROJECT" worktree add -q -b feature "$TMP/wrong-state-wt"
mkdir "$TMP/wrong-state-wt/.tower"
assert_false 'existing unrelated state rejected' dispatch "$PROJECT" T001 --prep --worktree "$TMP/wrong-state-wt"
assert_eq 'state rejection leaves card ready' "$(card_field "$PROJECT" T001 status)" ready

PROJECT="$TMP/inplace"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
assert_true 'in-place dispatch succeeds' dispatch "$PROJECT" T001 --prep --in-place
assert_eq 'in-place checks out recorded branch' "$(git -C "$PROJECT" branch --show-current)" "$(card_field "$PROJECT" T001 branch)"
assert_false 'in-place does not execute on main' test "$(git -C "$PROJECT" branch --show-current)" = main

PROJECT="$TMP/monorepo"
new_repo "$PROJECT"
mkdir -p "$PROJECT/alpha/api" "$PROJECT/beta/api"
new_project "$PROJECT/alpha/api"
new_project "$PROJECT/beta/api"
new_card "$PROJECT/alpha/api" T001
new_card "$PROJECT/beta/api" T001
assert_true 'first monorepo project dispatches' dispatch "$PROJECT/alpha/api" T001 --prep
assert_true 'second project can dispatch its own T001' dispatch "$PROJECT/beta/api" T001 --prep
assert_false 'same basename projects use different branches' test "$(card_field "$PROJECT/alpha/api" T001 branch)" = "$(card_field "$PROJECT/beta/api" T001 branch)"

PROJECT="$TMP/staged"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
echo pending > "$PROJECT/.tower/design.md"
git -C "$PROJECT/.tower" add design.md
assert_true 'dispatch with unrelated staged state succeeds' dispatch "$PROJECT" T001 --prep
assert_eq 'dispatch commit contains only its card' "$(git -C "$PROJECT/.tower" diff-tree --no-commit-id --name-only -r HEAD)" tasks/T001-test.md
assert_eq 'unrelated staged state remains staged' "$(git -C "$PROJECT/.tower" diff --cached --name-only)" design.md

PROJECT="$TMP/ownership"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001 'src/shared/**'
new_card "$PROJECT" T002 'src/shared/file.sh'
new_card "$PROJECT" T003 'src/shared-other/file.sh'
assert_true 'first owner claims its paths' dispatch "$PROJECT" T001 --prep
assert_false 'overlapping owner is rejected' dispatch "$PROJECT" T002 --prep
assert_eq 'rejected overlap remains ready' "$(card_field "$PROJECT" T002 status)" ready
assert_true 'sibling directory is not an overlap' dispatch "$PROJECT" T003 --prep
sed -i '' 's/status: in-flight/status: in-review/' "$PROJECT/.tower/tasks/T001-test.md"
assert_false 'review still reserves owned paths' dispatch "$PROJECT" T002 --prep
sed -i '' 's/status: in-review/status: merged/' "$PROJECT/.tower/tasks/T001-test.md"
assert_true 'merged owner releases its paths' dispatch "$PROJECT" T002 --prep

PROJECT="$TMP/parent-relative"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001 '../AGENTS.md'
new_card "$PROJECT" T002 '../../docs/guide.md'
new_card "$PROJECT" T003 '..'
new_card "$PROJECT" T004 'src/../escaped.sh'
new_card "$PROJECT" T005 '/etc/passwd'
new_card "$PROJECT" T006 '../'
assert_true 'a project in a subdirectory may own a repo-root file' dispatch "$PROJECT" T001 --prep
assert_true 'several leading ../ segments are allowed' dispatch "$PROJECT" T002 --prep
assert_false 'a bare .. names no file and is rejected' dispatch "$PROJECT" T003 --prep
assert_false 'traversal after a real segment is still rejected' dispatch "$PROJECT" T004 --prep
assert_false 'an absolute path is still rejected' dispatch "$PROJECT" T005 --prep
assert_false 'a trailing ../ names nothing and is rejected' dispatch "$PROJECT" T006 --prep

PROJECT="$TMP/unfilled-ownership"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001 'src/a.sh'
new_card "$PROJECT" T002 'src/b.sh'
sed -i '' 's/^- `src\/b.sh`$/To be filled in at promotion./' "$PROJECT/.tower/tasks/T002-test.md"
sed -i '' 's/status: ready/status: blocked/' "$PROJECT/.tower/tasks/T002-test.md"
assert_true "a blocked card's unfilled ownership does not block another dispatch" dispatch "$PROJECT" T001 --prep

PROJECT="$TMP/concurrent"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001 'src/shared.sh'
new_card "$PROJECT" T002 'src/shared.sh'
cat > "$PROJECT/.tower/.git/hooks/pre-commit" <<EOF
#!/usr/bin/env bash
if mkdir '$TMP/first-hook' 2>/dev/null; then
  touch '$TMP/committing'
  read -r -t 5 _ < '$TMP/release'
fi
EOF
chmod +x "$PROJECT/.tower/.git/hooks/pre-commit"
mkfifo "$TMP/release"
dispatch "$PROJECT" T001 --prep &
FIRST_PID=$!
for ((i=0; i<100; i++)); do
  [ ! -e "$TMP/committing" ] || break
  sleep 0.05
done
assert_true 'first dispatch reached commit' test -e "$TMP/committing"
assert_false 'concurrent overlapping dispatch is rejected' dispatch "$PROJECT" T002 --prep
echo continue > "$TMP/release"
wait "$FIRST_PID"
assert_status 'first dispatch completes' "$?" 0
assert_eq 'second card remains unclaimed' "$(card_field "$PROJECT" T002 status)" ready

PROJECT="$TMP/resume"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
mkdir "$TMP/fakebin"
printf '#!/usr/bin/env bash\nexit 127\n' > "$TMP/fakebin/claude"
chmod +x "$TMP/fakebin/claude"
export PATH="$TMP/fakebin:$PATH"
assert_false 'failed agent launch is reported' dispatch "$PROJECT" T001 --headless
BRANCH="$(card_field "$PROJECT" T001 branch)"
WT="$(git -C "$PROJECT" worktree list --porcelain | awk -v b="refs/heads/$BRANCH" '/^worktree / {p=substr($0,10)} $0=="branch " b {print p}')"
echo preserve > "$WT/uncommitted.txt"
printf '#!/usr/bin/env bash\nprintf "resumed" > resumed.txt\n' > "$TMP/fakebin/claude"
assert_true 'failed session can resume' dispatch "$PROJECT" T001 --resume --headless
assert_eq 'resume keeps task branch' "$(card_field "$PROJECT" T001 branch)" "$BRANCH"
assert_eq 'resume preserves uncommitted implementation' "$(cat "$WT/uncommitted.txt")" preserve
assert_true 'resumed agent runs inside original worktree' test -f "$WT/resumed.txt"
new_card "$PROJECT" T002
assert_false 'ready task cannot use resume' dispatch "$PROJECT" T002 --resume --prep
assert_true 'resume from linked worktree finds canonical project' dispatch "$WT" T001 --resume --headless

PROJECT="$TMP/quote's-project"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
assert_true 'quoted project path launches correctly' dispatch "$PROJECT" T001 --headless

PROJECT="$TMP/preparation"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
printf '#!/usr/bin/env bash\nexit 1\n' > "$PROJECT/.tower/.git/hooks/pre-commit"
chmod +x "$PROJECT/.tower/.git/hooks/pre-commit"
assert_false 'failed state commit is reported' dispatch "$PROJECT" T001 --prep
rm "$PROJECT/.tower/.git/hooks/pre-commit"
assert_true 'resume recovers failed state commit' dispatch "$PROJECT" T001 --resume --prep
assert_empty 'resumed preparation durably records its card' "$(git -C "$PROJECT/.tower" status --porcelain)"

PROJECT="$TMP/root-project"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
mkdir "$PROJECT/root-project"
new_project "$PROJECT/root-project"
new_card "$PROJECT/root-project" T001
assert_true 'root project dispatches' dispatch "$PROJECT" T001 --prep
assert_true 'same-named subproject has separate task namespace' dispatch "$PROJECT/root-project" T001 --prep

PROJECT="$TMP/vendor"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
printf '#!/usr/bin/env bash\nexit 127\n' > "$TMP/fakebin/codex"
chmod +x "$TMP/fakebin/codex"
assert_false 'overridden vendor launch fails as configured' dispatch "$PROJECT" T001 --vendor codex --headless
assert_eq 'card remembers dispatched vendor for resume' "$(card_field "$PROJECT" T001 vendor)" codex

summary
