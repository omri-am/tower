#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/tower-fixtures.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
new_repo "$TMP/project"
echo pending > "$TMP/project/unrelated.txt"
git -C "$TMP/project" add unrelated.txt
assert_true 'init succeeds with unrelated staged changes' "$ROOT/bin/tower-init" "$TMP/project"
unrelated_committed() { git -C "$TMP/project" cat-file -e HEAD:unrelated.txt 2>/dev/null; }
assert_false 'init does not commit unrelated file' unrelated_committed
assert_eq 'init preserves staged file' "$(git -C "$TMP/project" diff --cached --name-only)" unrelated.txt

new_repo "$TMP/sidecar"
assert_true 'sidecar init succeeds' "$ROOT/bin/tower-init" --sidecar "$TMP/sidecar"
SIDECAR_EXCLUDE="$(git -C "$TMP/sidecar" rev-parse --path-format=absolute --git-path info/exclude)"
assert_true 'sidecar init excludes .tower without a trailing slash' grep -qx '\.tower' "$SIDECAR_EXCLUDE"
assert_false 'sidecar init does not write the directory-only pattern' grep -qx '\.tower/' "$SIDECAR_EXCLUDE"
rm -rf "$TMP/sidecar/.tower"
"$ROOT/bin/tower-init" --sidecar "$TMP/sidecar" > /dev/null
assert_eq 're-running sidecar init keeps a single .tower line' "$(grep -cx '\.tower' "$SIDECAR_EXCLUDE")" 1

new_card "$TMP/sidecar" T001
dispatch "$TMP/sidecar" T001 --prep
SIDECAR_WT="$(git -C "$TMP/sidecar" worktree list --porcelain | sed -n 's/^worktree //p' | tail -1)"
assert_true 'dispatch drops a .tower symlink into the worktree' test -L "$SIDECAR_WT/.tower"
assert_true 'the dispatched .tower symlink is ignored' git -C "$SIDECAR_WT" check-ignore -q .tower
assert_empty 'the dispatched worktree shows no untracked tower files' "$(git -C "$SIDECAR_WT" status --porcelain)"
summary
