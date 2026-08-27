#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

new_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/.claude-plugin" "$dir/lib" "$dir/scripts"
  cp "$ROOT/lib/tower-semver.sh" "$ROOT/lib/tower-meta.sh" "$dir/lib/"
  cp "$ROOT/scripts/tower-release" "$dir/scripts/"
  chmod +x "$dir/scripts/tower-release"
  printf '{\n  "name": "tower",\n  "version": "0.1.0"\n}\n' > "$dir/.claude-plugin/plugin.json"
  printf '# Changelog\n\n## Unreleased\n\n- Something shipped.\n\n' > "$dir/CHANGELOG.md"
  git init -q "$dir"
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
}

R="$TMP/repo"

new_repo "$R"
"$R/scripts/tower-release" 0.0.9 >/dev/null 2>&1
assert_status "refuses a version that is not newer" "$?" "1"

new_repo "$R"
"$R/scripts/tower-release" 0.1.0 >/dev/null 2>&1
assert_status "refuses the same version" "$?" "1"

new_repo "$R"
"$R/scripts/tower-release" nonsense >/dev/null 2>&1
assert_status "refuses a malformed version" "$?" "1"

new_repo "$R"
printf 'dirt\n' > "$R/dirty.txt"
git -C "$R" add dirty.txt
"$R/scripts/tower-release" 0.2.0 >/dev/null 2>&1
assert_status "refuses a dirty tree with a staged change" "$?" "1"

new_repo "$R"
printf 'dirt\n' >> "$R/CHANGELOG.md"
"$R/scripts/tower-release" 0.2.0 >/dev/null 2>&1
assert_status "refuses a dirty tree with an unstaged change" "$?" "1"

new_repo "$R"
git -C "$R" tag v0.2.0
"$R/scripts/tower-release" 0.2.0 >/dev/null 2>&1
assert_status "refuses an existing tag" "$?" "1"

new_repo "$R"
printf '# Changelog\n\n## Unreleased\n\n## v0.1.0 — 2026-01-01\n\n- First.\n' > "$R/CHANGELOG.md"
git -C "$R" add -A
git -C "$R" commit -q -m changelog
"$R/scripts/tower-release" 0.2.0 >/dev/null 2>&1
assert_status "refuses an empty Unreleased section" "$?" "1"

new_repo "$R"
printf '# Changelog\n\n## Unreleased\n\n- First unreleased.\n\n## Unreleased\n\n- Second unreleased.\n' > "$R/CHANGELOG.md"
git -C "$R" add -A
git -C "$R" commit -q -m "duplicate unreleased heading"
"$R/scripts/tower-release" 0.2.0 >/dev/null 2>&1
assert_status "refuses a changelog with more than one Unreleased heading" "$?" "1"

new_repo "$R"
printf '{\n  "name": "tower",\n  "version": "0.1.0",\n  "engines": {\n    "version": "0a1a0"\n  }\n}\n' > "$R/.claude-plugin/plugin.json"
git -C "$R" add -A
git -C "$R" commit -q -m "nested version key"
"$R/scripts/tower-release" 0.2.0 >/dev/null 2>&1
assert_status "happy path succeeds with a nested version key present" "$?" "0"
assert_eq "top-level version bumped" "$(. "$ROOT/lib/tower-meta.sh"; tower_version "$R")" "0.2.0"
assert_eq "nested version key left untouched" "$(grep -c '\"version\": \"0a1a0\"' "$R/.claude-plugin/plugin.json")" "1"

new_repo "$R"
printf '{\n  "name": "tower",\n  "version":\n    "0.1.0"\n}\n' > "$R/.claude-plugin/plugin.json"
git -C "$R" add -A
git -C "$R" commit -q -m "version split across lines"
BEFORE_LOG="$(git -C "$R" log --format=%H)"
"$R/scripts/tower-release" 0.2.0 >/dev/null 2>&1
assert_status "refuses when the manifest rewrite does not take" "$?" "1"
assert_eq "no commit was made" "$(git -C "$R" log --format=%H)" "$BEFORE_LOG"
assert_eq "no tag was created" "$(git -C "$R" tag --list v0.2.0)" ""

new_repo "$R"
OUT="$("$R/scripts/tower-release" 0.2.0 2>&1)"
assert_status "happy path succeeds" "$?" "0"
assert_eq "manifest bumped" "$(. "$ROOT/lib/tower-meta.sh"; tower_version "$R")" "0.2.0"
assert_eq "tag created" "$(git -C "$R" tag --list v0.2.0)" "v0.2.0"
assert_eq "release heading written" "$(grep -c '^## v0\.2\.0 — [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$' "$R/CHANGELOG.md")" "1"
assert_eq "fresh Unreleased inserted" "$(grep -c '^## Unreleased$' "$R/CHANGELOG.md")" "1"
assert_eq "entry kept under the release heading" "$(grep -c 'Something shipped' "$R/CHANGELOG.md")" "1"
assert_eq "tree is clean after the commit" "$(git -C "$R" status --porcelain | wc -l | tr -d ' ')" "0"
assert_eq "push is suggested, not run" "$(printf '%s' "$OUT" | grep -c 'git push')" "1"
assert_eq "nothing was pushed" "$(git -C "$R" remote | wc -l | tr -d ' ')" "0"

summary
