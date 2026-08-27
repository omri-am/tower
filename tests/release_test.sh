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
ORIGIN="$TMP/origin.git"

new_tag_repo() {
  local dir="$1" version="$2"
  rm -rf "$dir" "$ORIGIN"
  git init -q --bare "$ORIGIN"
  mkdir -p "$dir/.claude-plugin" "$dir/lib" "$dir/scripts"
  cp "$ROOT/lib/tower-semver.sh" "$ROOT/lib/tower-meta.sh" "$dir/lib/"
  cp "$ROOT/scripts/tower-release" "$dir/scripts/"
  chmod +x "$dir/scripts/tower-release"
  printf '{\n  "name": "tower",\n  "version": "%s"\n}\n' "$version" > "$dir/.claude-plugin/plugin.json"
  printf '# Changelog\n\n## Unreleased\n\n- Something shipped.\n\n' > "$dir/CHANGELOG.md"
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  git -C "$dir" remote add origin "$ORIGIN"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "version $version"
  git -C "$dir" push -q origin main
}

new_tag_repo_no_push() {
  local dir="$1" version="$2"
  rm -rf "$dir" "$ORIGIN"
  git init -q --bare "$ORIGIN"
  mkdir -p "$dir/.claude-plugin" "$dir/lib" "$dir/scripts"
  cp "$ROOT/lib/tower-semver.sh" "$ROOT/lib/tower-meta.sh" "$dir/lib/"
  cp "$ROOT/scripts/tower-release" "$dir/scripts/"
  chmod +x "$dir/scripts/tower-release"
  printf '{\n  "name": "tower",\n  "version": "%s"\n}\n' "$version" > "$dir/.claude-plugin/plugin.json"
  printf '# Changelog\n\n## Unreleased\n\n- Something shipped.\n\n' > "$dir/CHANGELOG.md"
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  git -C "$dir" remote add origin "$ORIGIN"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "version $version"
}

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
printf '# Changelog\n\n## v0.1.0 — 2026-01-01\n\n- First.\n' > "$R/CHANGELOG.md"
git -C "$R" add -A
git -C "$R" commit -q -m "changelog with zero Unreleased headings"
OUT="$("$R/scripts/tower-release" 0.2.0 2>&1)"
assert_status "refuses a changelog with zero Unreleased headings" "$?" "1"
assert_eq "the zero-heading refusal names itself instead of dying silently" \
  "$(printf '%s' "$OUT" | grep -c "tower-release: CHANGELOG.md has 0 '## Unreleased' headings")" "1"

new_repo "$R"
printf '{\n  "name": "tower",\n  "version": "0.1.0",\n  "engines": {\n    "version": "0a1a0"\n  }\n}\n' > "$R/.claude-plugin/plugin.json"
git -C "$R" add -A
git -C "$R" commit -q -m "nested version key with an unrelated value"
"$R/scripts/tower-release" 0.2.0 >/dev/null 2>&1
assert_status "happy path succeeds with a differently-valued nested version key" "$?" "0"
assert_eq "top-level version bumped despite the nested key" "$(. "$ROOT/lib/tower-meta.sh"; tower_version "$R")" "0.2.0"
assert_eq "differently-valued nested version key left untouched" "$(grep -c '\"version\": \"0a1a0\"' "$R/.claude-plugin/plugin.json")" "1"

new_repo "$R"
printf '{\n  "name": "tower",\n  "version": "0.1.0",\n  "engines": {\n    "version": "0.1.0"\n  }\n}\n' > "$R/.claude-plugin/plugin.json"
git -C "$R" add -A
git -C "$R" commit -q -m "nested version key with the same value"
"$R/scripts/tower-release" 0.2.0 >/dev/null 2>&1
assert_status "happy path succeeds with a same-valued nested version key" "$?" "0"
assert_eq "top-level version bumped, not the nested one" "$(. "$ROOT/lib/tower-meta.sh"; tower_version "$R")" "0.2.0"
assert_eq "exactly one line reads the new version" "$(grep -c '\"version\": \"0.2.0\"' "$R/.claude-plugin/plugin.json")" "1"
assert_eq "the same-valued nested key still reads the old version" "$(grep -c '\"version\": \"0.1.0\"' "$R/.claude-plugin/plugin.json")" "1"

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
assert_status "phase 1 happy path succeeds" "$?" "0"
assert_eq "manifest bumped" "$(. "$ROOT/lib/tower-meta.sh"; tower_version "$R")" "0.2.0"
assert_eq "phase 1 creates no tag" "$(git -C "$R" tag --list v0.2.0)" ""
assert_eq "phase 1 switches to the release branch" "$(git -C "$R" symbolic-ref --short -q HEAD)" "release-v0.2.0"
assert_eq "release heading written" "$(grep -c '^## v0\.2\.0 — [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$' "$R/CHANGELOG.md")" "1"
assert_eq "fresh Unreleased inserted" "$(grep -c '^## Unreleased$' "$R/CHANGELOG.md")" "1"
assert_eq "entry kept under the release heading" "$(grep -c 'Something shipped' "$R/CHANGELOG.md")" "1"
assert_eq "tree is clean after the commit" "$(git -C "$R" status --porcelain | wc -l | tr -d ' ')" "0"
assert_eq "push of the branch is suggested, not run" "$(printf '%s' "$OUT" | grep -c 'git push')" "1"
assert_eq "nothing was pushed" "$(git -C "$R" remote | wc -l | tr -d ' ')" "0"
assert_eq "next step names the publish command" "$(printf '%s' "$OUT" | grep -c 'tower-release --tag 0.2.0')" "1"

new_repo "$R"
git -C "$R" branch release-v0.2.0
BEFORE_LOG="$(git -C "$R" log --format=%H)"
BEFORE_BRANCH="$(git -C "$R" symbolic-ref --short -q HEAD)"
OUT="$("$R/scripts/tower-release" 0.2.0 2>&1)"
assert_status "phase 1 refuses when the release branch already exists" "$?" "1"
assert_eq "the branch-exists refusal names itself" \
  "$(printf '%s' "$OUT" | grep -c 'tower-release: branch release-v0.2.0 already exists')" "1"
assert_eq "no commit was made when the release branch already exists" "$(git -C "$R" log --format=%H)" "$BEFORE_LOG"
assert_eq "still on the original branch when the release branch already exists" \
  "$(git -C "$R" symbolic-ref --short -q HEAD)" "$BEFORE_BRANCH"
assert_eq "manifest untouched when the release branch already exists" \
  "$(. "$ROOT/lib/tower-meta.sh"; tower_version "$R")" "0.1.0"

new_tag_repo "$R" "0.2.0"
printf 'dirt\n' >> "$R/CHANGELOG.md"
OUT="$("$R/scripts/tower-release" --tag 0.2.0 2>&1)"
assert_status "phase 2 refuses an unstaged change" "$?" "1"
assert_eq "the unstaged-change refusal names itself" \
  "$(printf '%s' "$OUT" | grep -c 'tower-release: working tree has unstaged changes')" "1"
assert_eq "no tag created when the tree is dirty" "$(git -C "$R" tag --list v0.2.0)" ""

new_tag_repo "$R" "0.2.0"
git -C "$R" checkout -q -b other
OUT="$("$R/scripts/tower-release" --tag 0.2.0 2>&1)"
assert_status "phase 2 refuses when not on main" "$?" "1"
assert_eq "the wrong-branch refusal names itself" \
  "$(printf '%s' "$OUT" | grep -c 'tower-release: current branch is other, not main')" "1"
assert_eq "no tag created off main" "$(git -C "$R" tag --list v0.2.0)" ""

new_tag_repo "$R" "0.2.0"
printf 'x\n' > "$R/extra.txt"
git -C "$R" add extra.txt
git -C "$R" commit -q -m "local-only commit"
OUT="$("$R/scripts/tower-release" --tag 0.2.0 2>&1)"
assert_status "phase 2 refuses when local main is out of sync with origin/main" "$?" "1"
assert_eq "the out-of-sync refusal names itself" \
  "$(printf '%s' "$OUT" | grep -c 'tower-release: local main does not match origin/main')" "1"
assert_eq "no tag created when out of sync with origin" "$(git -C "$R" tag --list v0.2.0)" ""

new_tag_repo_no_push "$R" "0.2.0"
OUT="$("$R/scripts/tower-release" --tag 0.2.0 2>&1)"
assert_status "phase 2 refuses cleanly when origin has no main - exit 1, not git's raw 128" "$?" "1"
assert_eq "the no-origin-main refusal names itself" \
  "$(printf '%s' "$OUT" | grep -c 'tower-release: cannot resolve origin/main')" "1"
assert_eq "every line of the refusal carries the tower-release prefix" \
  "$(printf '%s\n' "$OUT" | grep -vc '^tower-release:')" "0"
assert_eq "no tag created when origin has no main" "$(git -C "$R" tag --list v0.2.0)" ""

new_tag_repo "$R" "0.1.0"
OUT="$("$R/scripts/tower-release" --tag 0.2.0 2>&1)"
assert_status "phase 2 refuses when the manifest does not read the tagged version" "$?" "1"
assert_eq "the manifest-mismatch refusal names itself" \
  "$(printf '%s' "$OUT" | grep -c 'tower-release: manifest reads 0.1.0, not 0.2.0')" "1"
assert_eq "no tag created on manifest mismatch" "$(git -C "$R" tag --list v0.2.0)" ""

new_tag_repo "$R" "0.2.0"
git -C "$R" tag v0.2.0
OUT="$("$R/scripts/tower-release" --tag 0.2.0 2>&1)"
assert_status "phase 2 refuses an existing tag" "$?" "1"
assert_eq "the existing-tag refusal names itself" \
  "$(printf '%s' "$OUT" | grep -c 'tower-release: tag v0.2.0 already exists')" "1"

new_tag_repo "$R" "0.2.0"
OUT="$("$R/scripts/tower-release" --tag 0.2.0 2>&1)"
assert_status "phase 2 happy path succeeds" "$?" "0"
assert_eq "tag created" "$(git -C "$R" tag --list v0.2.0)" "v0.2.0"
assert_eq "tag points at main's tip" "$(git -C "$R" rev-parse v0.2.0)" "$(git -C "$R" rev-parse main)"
assert_eq "push of the tag is suggested, not run" "$(printf '%s' "$OUT" | grep -c 'git push')" "1"
assert_eq "nothing was pushed to origin" "$(git --git-dir="$ORIGIN" tag --list v0.2.0)" ""
assert_eq "tree is clean after tagging" "$(git -C "$R" status --porcelain | wc -l | tr -d ' ')" "0"

new_tag_repo "$R" "0.1.0"
"$R/scripts/tower-release" 0.2.0 >/dev/null 2>&1
RELEASE_COMMIT="$(git -C "$R" rev-parse release-v0.2.0)"
git -C "$R" checkout -q main
printf '{\n  "name": "tower",\n  "version": "0.2.0"\n}\n' > "$R/.claude-plugin/plugin.json"
printf '# Changelog\n\n## Unreleased\n\n## v0.2.0 — 2026-01-01\n\n- Something shipped.\n\n' > "$R/CHANGELOG.md"
git -C "$R" add -A
git -C "$R" commit -q -m "Release v0.2.0 (#1)"
git -C "$R" branch -q -D release-v0.2.0
git -C "$R" push -q origin main
assert_false "the original release commit is not an ancestor of main after a simulated squash merge" \
  git -C "$R" merge-base --is-ancestor "$RELEASE_COMMIT" main
OUT="$("$R/scripts/tower-release" --tag 0.2.0 2>&1)"
assert_status "phase 2 tags correctly after a simulated squash merge" "$?" "0"
assert_eq "tag points at main's tip, not at the unreachable release commit" \
  "$(git -C "$R" rev-parse v0.2.0)" "$(git -C "$R" rev-parse main)"

summary
