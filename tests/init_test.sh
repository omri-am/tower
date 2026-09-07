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
summary
