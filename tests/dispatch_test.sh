#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/tower-fixtures.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

"$ROOT/bin/tower-dispatch" > "$TMP/usage.stdout" 2> "$TMP/usage.stderr"
assert_status 'missing task exits with usage' "$?" 1
printf '%s\n' 'usage: tower-dispatch <task-id> [--vendor claude|codex] [--model <name>] [--effort <level>] [--headless] [--here] [--prep] [--print-only] [--in-place] [--worktree <path>] [--resume] [--expect-revision <hash>]' > "$TMP/expected-usage"
assert_true 'usage is byte-identical' cmp -s "$TMP/expected-usage" "$TMP/usage.stderr"
assert_empty 'usage has no stdout' "$(cat "$TMP/usage.stdout")"

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

PROJECT="$TMP/model"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
assert_true 'dispatch without model or effort prints its command' dispatch "$PROJECT" T001 --print-only
assert_false 'command without the flags names no model' grep -q -e '--model' -e '--effort' "$TMP/dispatch.out"
assert_true 'model is accepted' dispatch "$PROJECT" T001 --model opus --print-only
assert_true 'claude command carries the requested model' grep -q 'claude -n [^ ]* --model opus ' "$TMP/dispatch.out"
assert_true 'effort is accepted' dispatch "$PROJECT" T001 --effort high --print-only
assert_true 'claude command carries the requested effort' grep -q -- '--effort high ' "$TMP/dispatch.out"
assert_true 'codex dispatch with a model still succeeds' dispatch "$PROJECT" T001 --vendor codex --model opus --effort high --print-only
grep '^cd ' "$TMP/dispatch.out" > "$TMP/codex-command"
assert_true 'codex command carries model and effort' grep -q ' codex --model opus -c model_reasoning_effort=high ' "$TMP/codex-command"
assert_false 'codex model and effort cause no warning' grep -q 'warning:' "$TMP/dispatch.out"
assert_true 'headless codex dispatch with a model succeeds' dispatch "$PROJECT" T001 --vendor codex --headless --model opus --effort high --print-only
grep '^cd ' "$TMP/dispatch.out" > "$TMP/codex-command"
assert_true 'headless codex command carries model and effort' grep -q ' codex exec --model opus -c model_reasoning_effort=high ' "$TMP/codex-command"
assert_false 'headless codex model and effort cause no warning' grep -q 'warning:' "$TMP/dispatch.out"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "$TOWER_TEST_ARGS"\nexit 1\n' > "$TMP/fakebin/claude"
export TOWER_TEST_ARGS="$TMP/claude-args"
assert_false 'dispatch with model and effort launches the agent' dispatch "$PROJECT" T001 --model opus --effort high --headless
assert_eq 'card records the dispatched model' "$(card_field "$PROJECT" T001 model)" opus
assert_eq 'card records the dispatched effort' "$(card_field "$PROJECT" T001 effort)" high
rm "$TOWER_TEST_ARGS"
assert_false 'resumed agent launches again' dispatch "$PROJECT" T001 --resume --headless
assert_true 'resume reuses the recorded model' grep -qx opus "$TOWER_TEST_ARGS"
assert_true 'resume reuses the recorded effort' grep -qx high "$TOWER_TEST_ARGS"
rm "$TOWER_TEST_ARGS"
assert_false 'resume with a new model launches again' dispatch "$PROJECT" T001 --resume --model sonnet --headless
assert_true 'a model flag on resume overrides the recorded model' grep -qx sonnet "$TOWER_TEST_ARGS"
assert_false 'an overridden model is not also passed' grep -qx opus "$TOWER_TEST_ARGS"
assert_eq 'resume with a new model leaves the recorded model' "$(card_field "$PROJECT" T001 model)" opus
assert_true 'overriding the model on resume keeps the recorded effort' grep -qx high "$TOWER_TEST_ARGS"
new_card "$PROJECT" T002
sed -i '' 's/^vendor: claude$/vendor: claude\nmodel: ""\neffort: ""/' "$PROJECT/.tower/tasks/T002-test.md"
git -C "$PROJECT/.tower" commit -q -am 'tower: add model fields to T002'
assert_true 'card with empty model fields dispatches' dispatch "$PROJECT" T002 --model opus --prep
assert_eq 'empty model field is filled in place' "$(grep -c '^model:' "$PROJECT/.tower/tasks/T002-test.md")" 1
assert_eq 'filled model field holds the model' "$(card_field "$PROJECT" T002 model)" opus
assert_eq 'unset effort field stays empty' "$(card_field "$PROJECT" T002 effort)" ""
assert_eq 'unset effort field is kept' "$(grep -c '^effort:' "$PROJECT/.tower/tasks/T002-test.md")" 1
new_card "$PROJECT" T003
assert_true 'model with a backslash dispatches' dispatch "$PROJECT" T003 --model 'a\tb' --prep
assert_eq 'card keeps a backslash in the model literally' "$(card_field "$PROJECT" T003 model)" 'a\tb'

PROJECT="$TMP/claude-golden"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
PROJECT="$(cd "$PROJECT" && pwd -P)"
WORKTREE="$(cd "$TMP" && pwd -P)/claude-golden-tower-worktrees/root/T001"
SESSION="$("$ROOT/bin/tower-session-name" --task T001 --from "$PROJECT")"
PROMPT="$PROJECT/.tower/prompts/T001-prompt.md"
assert_claude_command() {
  local label="$1" arguments="$2"
  shift 2
  (cd "$PROJECT" && "$ROOT/bin/tower-dispatch" T001 "$@" --print-only) > "$TMP/golden.stdout" 2> "$TMP/golden.stderr"
  assert_status "$label dispatch succeeds" "$?" 0
  assert_eq "$label command is unchanged" "$(cat "$TMP/golden.stdout")" "cd $WORKTREE && TOWER_TASK=T001 claude $arguments \"\$(cat $PROMPT)\""
  assert_empty "$label has no stderr" "$(cat "$TMP/golden.stderr")"
}
assert_claude_command 'claude' "-n $SESSION"
assert_claude_command 'claude with model' "-n $SESSION --model opus" --model opus
assert_claude_command 'claude with effort' "-n $SESSION --effort high" --effort high
assert_claude_command 'claude with model and effort' "-n $SESSION --model opus --effort high" --model opus --effort high
assert_claude_command 'headless claude' "-n $SESSION -p" --headless
assert_claude_command 'headless claude with model' "-n $SESSION -p --model opus" --headless --model opus
assert_claude_command 'headless claude with effort' "-n $SESSION -p --effort high" --headless --effort high
assert_claude_command 'headless claude with model and effort' "-n $SESSION -p --model opus --effort high" --headless --model opus --effort high

sed -i '' 's/^vendor: claude$/vendor: any/' "$PROJECT/.tower/tasks/T001-test.md"
assert_true 'any vendor uses the table default' dispatch "$PROJECT" T001 --print-only
grep '^cd ' "$TMP/dispatch.out" > "$TMP/default-command"
assert_true 'default command launches claude' grep -q ' claude -n ' "$TMP/default-command"
assert_false 'unknown vendor is rejected' dispatch "$PROJECT" T001 --vendor bogus --print-only
assert_eq 'unknown vendor error is unchanged' "$(cat "$TMP/dispatch.out")" "tower-dispatch: unknown vendor 'bogus'"

(
  . "$ROOT/lib/tower-dispatch.sh"
  LAUNCH_ADAPTERS='fake - - -n - - -'
  VENDOR=fake MODE=terminal MODEL=m EFFORT=e
  prepare_launch name
  printf '%s\n' "${AGENT_ARGS[*]}"
) > "$TMP/none.stdout" 2> "$TMP/none.stderr"
assert_eq 'adapter row without model or effort flags passes only its session flag' "$(cat "$TMP/none.stdout")" '-n name'
printf '%s\n' "tower-dispatch: warning: fake does not take --model from tower; ignoring 'm'" "tower-dispatch: warning: fake does not take --effort from tower; ignoring 'e'" > "$TMP/expected-none"
assert_true 'adapter row without model or effort flags warns for both values' cmp -s "$TMP/expected-none" "$TMP/none.stderr"

PROJECT="$TMP/ambiguous-id"
new_repo "$PROJECT"
new_project "$PROJECT"
new_card "$PROJECT" T001
cp "$PROJECT/.tower/tasks/T001-test.md" "$PROJECT/.tower/tasks/T001-other.md"
assert_false 'ambiguous card id refuses to guess' dispatch "$PROJECT" T001 --prep
assert_eq 'ambiguous dispatch leaves status untouched' "$(card_field "$PROJECT" T001 status)" ready

for MODE in --print-only --prep --resume --headless; do
  set -- "$MODE"
  [ "$MODE" != --resume ] || set -- --resume --prep
  PROJECT="$TMP/duplicates-${MODE#--}"
  new_repo "$PROJECT"
  new_project "$PROJECT"
  new_card "$PROJECT" T001
  if [ "$MODE" = --resume ]; then
    dispatch "$PROJECT" T001 --prep
  fi
  new_card "$PROJECT" T002
  new_card "$PROJECT" T003
  cp "$PROJECT/.tower/tasks/T002-test.md" "$PROJECT/.tower/tasks/Z002-other.md"
  cp "$PROJECT/.tower/tasks/T003-test.md" "$PROJECT/.tower/tasks/A003-other.md"
  printf 'id: T999\n' >> "$PROJECT/.tower/tasks/T002-test.md"
  sed -i '' '/^id: T002$/a\
id: T999
' "$PROJECT/.tower/tasks/Z002-other.md"
  printf '%s\n' '---' 'title: No id' '---' 'id: T002' > "$PROJECT/.tower/tasks/no-id.md"
  mkdir "$PROJECT/.tower/tasks/nested"
  cp "$PROJECT/.tower/tasks/T002-test.md" "$PROJECT/.tower/tasks/nested/ignored.md"
  cp -R "$PROJECT/.tower/tasks" "$TMP/cards-${MODE#--}"
  BEFORE_BRANCHES="$(git -C "$PROJECT" for-each-ref refs/heads)"
  BEFORE_WORKTREES="$(git -C "$PROJECT" worktree list --porcelain)"
  cat > "$TMP/expected-duplicates" <<EOF
tower-dispatch: refusing to dispatch - duplicate task ids on the board:
  T002: T002-test.md Z002-other.md
  T003: A003-other.md T003-test.md
tower-dispatch: rename all but one card per id, then retry
EOF
  (cd "$PROJECT" && "$ROOT/bin/tower-dispatch" T001 "$@") > "$TMP/duplicate.stdout" 2> "$TMP/duplicate.stderr"
  assert_status "$MODE refuses an unrelated duplicated id" "$?" 1
  assert_true "$MODE names every duplicate in sorted order on stderr" cmp -s "$TMP/expected-duplicates" "$TMP/duplicate.stderr"
  assert_empty "$MODE refusal has no stdout" "$(cat "$TMP/duplicate.stdout")"
  assert_true "$MODE preserves all card bytes" diff -r "$TMP/cards-${MODE#--}" "$PROJECT/.tower/tasks"
  assert_eq "$MODE creates no branch" "$(git -C "$PROJECT" for-each-ref refs/heads)" "$BEFORE_BRANCHES"
  assert_eq "$MODE creates no worktree" "$(git -C "$PROJECT" worktree list --porcelain)" "$BEFORE_WORKTREES"
  assert_false "$MODE leaves no dispatch lock" test -e "$PROJECT/.tower/.git/tower-dispatch.lock"
  mkdir "$PROJECT/.tower/.git/tower-dispatch.lock"
  dispatch "$PROJECT" T001 "$@"
  assert_true "$MODE detects duplicates before attempting the existing lock" cmp -s "$TMP/expected-duplicates" "$TMP/dispatch.out"
done

summary
