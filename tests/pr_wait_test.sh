#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
. "$ROOT/tests/lib.sh"

PR_WAIT="$ROOT/bin/tower-pr-wait"

PROJECT="$(mktemp -d)"
trap 'rm -rf "$PROJECT"' EXIT
TASKS="$PROJECT/.tower/tasks"
mkdir -p "$TASKS"
export TOWER_PROJECT_DIR="$PROJECT"

printf -- '---\nid: T001\nstatus: in-review\npr: ""\n---\nbody\n' > "$TASKS/T001-single.md"
printf -- '---\nid: T900\nstatus: in-review\npr: "https://github.com/owner/repo/pull/1"\n---\nbody\n' > "$TASKS/T900-a.md"
printf -- '---\nid: T900\nstatus: in-review\npr: "https://github.com/owner/repo/pull/2"\n---\nbody\n' > "$TASKS/T900-b.md"

SINGLE_OUT="$("$PR_WAIT" T001 2>&1)"
SINGLE_STATUS=$?
assert_status "one match resolves the card and stops at the empty pr field" "$SINGLE_STATUS" "1"
assert_eq "one match reports the missing pr field, not a lookup failure" \
  "$(printf '%s\n' "$SINGLE_OUT" | grep -c 'card T001 has no pr: field')" "1"

MISSING_OUT="$("$PR_WAIT" T404 2>&1)"
MISSING_STATUS=$?
assert_status "zero matches fails" "$MISSING_STATUS" "1"
assert_eq "zero matches names the missing id" \
  "$(printf '%s\n' "$MISSING_OUT" | grep -c 'no card for T404')" "1"

AMBIGUOUS_OUT="$("$PR_WAIT" T900 2>&1)"
AMBIGUOUS_STATUS=$?
assert_status "two matches fail instead of guessing" "$AMBIGUOUS_STATUS" "1"
assert_eq "two matches name every matching file" \
  "$(printf '%s\n' "$AMBIGUOUS_OUT" | grep -c 'T900-a.md\|T900-b.md')" "2"
assert_eq "two matches never reach the pr field" \
  "$(printf '%s\n' "$AMBIGUOUS_OUT" | grep -c 'pr: field')" "0"

PR="https://github.com/owner/repo/pull/50"
printf -- '---\nid: T050\nstatus: in-review\npr: "%s"\n---\nbody\n' "$PR" > "$TASKS/T050-single.md"

FAKE_BIN="$PROJECT/fake-bin"
mkdir -p "$FAKE_BIN"
export FAKE_GH_STATES="$PROJECT/gh-states"
export FAKE_GH_CALLS="$PROJECT/gh-calls"
FAKE_GH_ERR="$PROJECT/gh-stderr"
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf 'call\n' >> "$FAKE_GH_CALLS"
state="$(sed -n '1p' "$FAKE_GH_STATES")"
if [ "$(wc -l < "$FAKE_GH_STATES")" -gt 1 ]; then
  sed '1d' "$FAKE_GH_STATES" > "$FAKE_GH_STATES.next"
  mv "$FAKE_GH_STATES.next" "$FAKE_GH_STATES"
fi
if [ "$state" = FAIL ]; then
  exit 1
fi
printf '%s\n' "$state"
EOF
chmod +x "$FAKE_BIN/gh"

run_pr_wait() {
  printf '%s\n' "$1" > "$FAKE_GH_STATES"
  : > "$FAKE_GH_CALLS"
  shift
  WATCH_OUT="$(PATH="$FAKE_BIN:$PATH" "$PR_WAIT" T050 "$@" 2> "$FAKE_GH_ERR")"
  WATCH_STATUS=$?
  WATCH_ERR="$(cat "$FAKE_GH_ERR")"
}

run_watch() {
  local states="$1"
  shift
  run_pr_wait "$states" --interval 1 "$@"
}

START_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
run_watch OPEN --max-wait 3
ELAPSED_MS=$(( $(python3 -c 'import time; print(int(time.time()*1000))') - START_MS ))
assert_status "open PR reaches the wait limit" "$WATCH_STATUS" "3"
assert_eq "wait limit reports the open PR" "$WATCH_OUT" "OPEN $PR"
assert_true "wait limit polls more than once" test "$(wc -l < "$FAKE_GH_CALLS")" -ge 2
assert_true "wait limit finishes within four seconds" test "$ELAPSED_MS" -le 4000

run_watch FAIL --max-wait 2
assert_status "failed gh calls reach the wait limit" "$WATCH_STATUS" "3"
assert_eq "failed gh calls report the open PR" "$WATCH_OUT" "OPEN $PR"

START_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
run_watch OPEN --interval 30 --max-wait 2
ELAPSED_MS=$(( $(python3 -c 'import time; print(int(time.time()*1000))') - START_MS ))
assert_status "a long interval still stops at the wait limit" "$WATCH_STATUS" "3"
assert_eq "a long interval reports the open PR at the wait limit" "$WATCH_OUT" "OPEN $PR"
assert_true "a long interval does not sleep past the wait limit" test "$ELAPSED_MS" -le 3500

run_watch $'OPEN\nMERGED' --interval 30 --max-wait 2
assert_status "a merge during the last sleep is seen at the wait limit" "$WATCH_STATUS" "0"
assert_eq "the final poll at the wait limit reports the merge" "$WATCH_OUT" "MERGED $PR"
assert_eq "the wait limit polls once more before it stops" \
  "$(wc -l < "$FAKE_GH_CALLS" | tr -d ' ')" "2"

run_watch MERGED --max-wait 30
assert_status "merged PR exits successfully with a limit" "$WATCH_STATUS" "0"
assert_eq "merged PR is reported with a limit" "$WATCH_OUT" "MERGED $PR"

run_watch CLOSED --max-wait 30
assert_status "closed PR exits successfully with a limit" "$WATCH_STATUS" "0"
assert_eq "closed PR is reported with a limit" "$WATCH_OUT" "CLOSED $PR"

run_watch MERGED
assert_status "merged PR exits successfully without a limit" "$WATCH_STATUS" "0"
assert_eq "merged PR is reported without a limit" "$WATCH_OUT" "MERGED $PR"

run_watch CLOSED
assert_status "closed PR exits successfully without a limit" "$WATCH_STATUS" "0"
assert_eq "closed PR is reported without a limit" "$WATCH_OUT" "CLOSED $PR"

START_MS="$(python3 -c 'import time; print(int(time.time()*1000))')"
run_watch $'OPEN\nMERGED'
ELAPSED_MS=$(( $(python3 -c 'import time; print(int(time.time()*1000))') - START_MS ))
assert_status "open PR later merges without a limit" "$WATCH_STATUS" "0"
assert_eq "later merge is reported without a limit" "$WATCH_OUT" "MERGED $PR"
assert_eq "later merge needs two polls" "$(wc -l < "$FAKE_GH_CALLS" | tr -d ' ')" "2"
assert_true "guard: interval 1 sleeps one second, not the default 120" test "$ELAPSED_MS" -le 3000

for value in 0 -5 abc 007; do
  run_watch OPEN --max-wait "$value"
  assert_status "invalid max-wait $value exits with usage error" "$WATCH_STATUS" "1"
  assert_eq "invalid max-wait $value prints usage" \
    "$(printf '%s\n' "$WATCH_ERR" | grep -c 'usage: tower-pr-wait')" "1"
  assert_eq "invalid max-wait $value skips gh" "$(wc -l < "$FAKE_GH_CALLS" | tr -d ' ')" "0"
done

run_watch OPEN --max-wait
assert_status "missing max-wait value exits with usage error" "$WATCH_STATUS" "1"
assert_eq "missing max-wait value prints usage" \
  "$(printf '%s\n' "$WATCH_ERR" | grep -c 'usage: tower-pr-wait')" "1"
assert_eq "missing max-wait value skips gh" "$(wc -l < "$FAKE_GH_CALLS" | tr -d ' ')" "0"

USAGE_LINE="usage: tower-pr-wait [<task-id>] [--interval seconds] [--max-wait seconds]"

for value in 1.5 0 -2 abc 007; do
  run_pr_wait OPEN --interval "$value" --max-wait 2
  assert_eq "invalid interval $value exits 1 with the usage line" \
    "$WATCH_STATUS $(printf '%s\n' "$WATCH_ERR" | tail -1)" "1 $USAGE_LINE"
  assert_eq "invalid interval $value skips gh" "$(wc -l < "$FAKE_GH_CALLS" | tr -d ' ')" "0"
done

run_pr_wait OPEN --max-wait 2 --interval
assert_eq "guard: missing interval value exits 1 with the usage line" \
  "$WATCH_STATUS $(printf '%s\n' "$WATCH_ERR" | tail -1)" "1 $USAGE_LINE"
assert_eq "guard: missing interval value skips gh" "$(wc -l < "$FAKE_GH_CALLS" | tr -d ' ')" "0"

run_pr_wait MERGED
assert_eq "guard: the default interval reports the merge without a limit" \
  "$WATCH_STATUS $WATCH_OUT" "0 MERGED $PR"

run_pr_wait MERGED --max-wait 30
assert_eq "guard: the default interval reports the merge with a limit" \
  "$WATCH_STATUS $WATCH_OUT" "0 MERGED $PR"

run_pr_wait MERGED --interval 5
assert_eq "guard: interval 5 reports the merge without a limit" \
  "$WATCH_STATUS $WATCH_OUT" "0 MERGED $PR"

run_pr_wait MERGED --interval 5 --max-wait 30
assert_eq "guard: interval 5 reports the merge with a limit" \
  "$WATCH_STATUS $WATCH_OUT" "0 MERGED $PR"

summary
