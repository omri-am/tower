#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"

SCRIPT="$ROOT/scripts/tower-changelog-check"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"

new_repo() {
  rm -rf "$R"
  mkdir -p "$R/bin" "$R/lib" "$R/hooks" "$R/scripts" "$R/skills/thing" \
    "$R/templates" "$R/commands" "$R/.claude-plugin" "$R/tests" "$R/docs"
  cp "$SCRIPT" "$R/scripts/tower-changelog-check"
  chmod +x "$R/scripts/tower-changelog-check"
  printf 'code\n' > "$R/bin/tower-thing"
  printf 'code\n' > "$R/lib/tower-thing.sh"
  printf 'code\n' > "$R/hooks/tower-thing.sh"
  printf 'code\n' > "$R/scripts/other-thing"
  printf 'code\n' > "$R/skills/thing/SKILL.md"
  printf 'code\n' > "$R/templates/thing.md"
  printf 'code\n' > "$R/commands/thing.md"
  printf '{}\n' > "$R/.claude-plugin/plugin.json"
  printf '1\n' > "$R/PROTOCOL_VERSION"
  printf 'test\n' > "$R/tests/thing_test.sh"
  printf 'doc\n' > "$R/docs/thing.md"
  printf 'readme\n' > "$R/README.md"
  printf 'protocol\n' > "$R/PROTOCOL.md"
  printf 'license\n' > "$R/LICENSE"
  printf '# Changelog\n\n## Unreleased\n\n' > "$R/CHANGELOG.md"
  git init -q "$R"
  git -C "$R" symbolic-ref HEAD refs/heads/main
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  git -C "$R" add -A
  git -C "$R" commit -q -m init
}

run_check() {
  "$R/scripts/tower-changelog-check" "$@"
}

TRIGGER_PATHS="bin/tower-thing lib/tower-thing.sh hooks/tower-thing.sh scripts/other-thing skills/thing/SKILL.md templates/thing.md commands/thing.md .claude-plugin/plugin.json PROTOCOL_VERSION"

for p in $TRIGGER_PATHS; do
  new_repo
  git -C "$R" checkout -q -b feature
  printf 'changed\n' >> "$R/$p"
  git -C "$R" commit -qam "touch $p"
  OUT="$(run_check main 2>&1)"
  assert_status "changing $p without a changelog entry fails" "$?" "1"
  assert_eq "failure names $p" "$(printf '%s' "$OUT" | grep -c "$p")" "1"
  assert_eq "every line of the failure carries the tower-changelog-check prefix" \
    "$(printf '%s\n' "$OUT" | grep -vc '^tower-changelog-check:')" "0"
done

NONTRIGGER_PATHS="tests/thing_test.sh docs/thing.md README.md PROTOCOL.md LICENSE"

for p in $NONTRIGGER_PATHS; do
  new_repo
  git -C "$R" checkout -q -b feature
  printf 'changed\n' >> "$R/$p"
  git -C "$R" commit -qam "touch $p"
  OUT="$(run_check main 2>&1)"
  assert_status "changing only $p passes without a changelog entry" "$?" "0"
  assert_empty "success for $p is quiet" "$OUT"
done

new_repo
git -C "$R" checkout -q -b feature
printf 'more code\n' >> "$R/bin/tower-thing"
printf '%s\n' '- Added a thing.' >> "$R/CHANGELOG.md"
git -C "$R" commit -qam "code change with a changelog entry"
OUT="$(run_check main 2>&1)"
assert_status "a code change with a matching changelog entry passes" "$?" "0"
assert_empty "success is quiet" "$OUT"

new_repo
git -C "$R" checkout -q -b feature
OUT="$(run_check main 2>&1)"
assert_status "an empty diff passes" "$?" "0"
assert_empty "empty diff produces no output" "$OUT"

new_repo
OUT="$(run_check does-not-exist-anywhere 2>&1)"
assert_status "an unresolvable base fails" "$?" "1"
assert_eq "the unresolvable-base failure is prefixed, not a raw git error" \
  "$(printf '%s' "$OUT" | grep -c '^tower-changelog-check: cannot resolve base')" "1"
assert_eq "no raw git fatal line leaks through" "$(printf '%s\n' "$OUT" | grep -c '^fatal:')" "0"

new_repo
git -C "$R" update-ref refs/remotes/origin/main "$(git -C "$R" rev-parse main)"
git -C "$R" checkout -q -b feature
printf 'more code\n' >> "$R/bin/tower-thing"
git -C "$R" commit -qam "code change, default base"
OUT="$(run_check 2>&1)"
assert_status "with no argument the default base origin/main is used" "$?" "1"
assert_eq "default-base failure names bin/tower-thing" "$(printf '%s' "$OUT" | grep -c 'bin/tower-thing')" "1"

new_repo
git -C "$R" checkout -q -b feature
printf 'doc update\n' >> "$R/docs/thing.md"
git -C "$R" commit -qam "docs only on feature"
git -C "$R" checkout -q main
printf 'unrelated main progress\n' >> "$R/bin/tower-thing"
git -C "$R" commit -qam "main moves ahead independently, without touching feature"
git -C "$R" checkout -q feature
OUT="$(run_check main 2>&1)"
assert_status \
  "merge-base: a docs-only feature branch passes even though main moved ahead with an unrelated code change" \
  "$?" "0"
assert_empty "merge-base success is quiet" "$OUT"

summary
