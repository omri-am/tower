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

summary
