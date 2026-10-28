#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/tower-fixtures.sh"

TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

MAIN="$TMP/main"
new_repo "$MAIN"
mkdir "$MAIN/.tower"

WT="$TMP/worktree"
git -C "$MAIN" worktree add -q -b feature "$WT"
mkdir "$WT/.tower" "$WT/src"

OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE/.tower" "$OUTSIDE/src"

mkdir "$TMP/fake-bin"
cat > "$TMP/fake-bin/git" <<'EOF'
#!/bin/sh
printf '%s\n' 'fatal: fake git failure' 'hint: second line' >&2
exit 1
EOF
chmod +x "$TMP/fake-bin/git"

run_locate() {
  local path="$1"
  shift
  LOCATE_OUT="$(PATH="$path" "$ROOT/bin/tower-locate" "$@" 2> "$TMP/locate.stderr")"
  LOCATE_STATUS=$?
  LOCATE_ERR="$(cat "$TMP/locate.stderr")"
}

FAILING_GIT_PATH="$TMP/fake-bin:$PATH"
run_locate "$FAILING_GIT_PATH" --from "$WT/src"
assert_eq 'worktree git failure warns with the first stderr line' "$LOCATE_ERR" "tower-locate: git failed in $WT/src: fatal: fake git failure; worktree mapping skipped"
assert_eq 'guard: failing git keeps the per-branch ancestor resolution' "$LOCATE_OUT" "$WT"$'\n'ancestor
assert_status 'guard: failing git keeps the successful exit status' "$LOCATE_STATUS" 0

run_locate "$FAILING_GIT_PATH" --from "$WT/src" --quiet
assert_empty 'guard: quiet suppresses the git failure warning' "$LOCATE_ERR"
assert_eq 'guard: quiet keeps the per-branch ancestor resolution' "$LOCATE_OUT" "$WT"$'\n'ancestor
assert_status 'guard: quiet keeps the successful exit status' "$LOCATE_STATUS" 0

run_locate "$FAILING_GIT_PATH" --from "$OUTSIDE/src"
assert_empty 'guard: no git entry produces no warning' "$LOCATE_ERR"
assert_eq 'guard: outside repository resolves its ancestor' "$LOCATE_OUT" "$OUTSIDE"$'\n'ancestor
assert_status 'guard: outside repository exits successfully' "$LOCATE_STATUS" 0

run_locate "$PATH" --from "$WT/src"
assert_eq 'guard: working git reports the per-branch copy' "$LOCATE_ERR" "tower-locate: $WT/.tower is a per-branch copy in a linked worktree (non-sidecar mode) - preferring the main checkout"
assert_eq 'guard: working git maps to the main checkout' "$LOCATE_OUT" "$MAIN"$'\n'worktree
assert_status 'guard: working git exits successfully' "$LOCATE_STATUS" 0

summary
