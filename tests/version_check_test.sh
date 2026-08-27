#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"

CHECK="$ROOT/bin/tower-version-check"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_ROOT="$TMP/root"
mkdir -p "$FAKE_ROOT/.claude-plugin" "$FAKE_ROOT/bin" "$FAKE_ROOT/lib" "$FAKE_ROOT/skills"
printf '{"name":"tower","version":"0.3.1"}' > "$FAKE_ROOT/.claude-plugin/plugin.json"
cp "$ROOT/lib/tower-semver.sh" "$ROOT/lib/tower-meta.sh" "$FAKE_ROOT/lib/"
cp "$CHECK" "$FAKE_ROOT/bin/"

REMOTE="$TMP/remote"
git init -q "$REMOTE"
git -C "$REMOTE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REMOTE" tag v0.1.0
git -C "$REMOTE" tag v0.4.0
git -C "$REMOTE" tag v0.2.0

CACHE="$TMP/cache"
run_check() {
  env TOWER_ROOT="$FAKE_ROOT" TOWER_VERSION_REMOTE="$REMOTE" TOWER_CACHE_DIR="$CACHE" \
      HOME="$TMP/fakehome" "$@" 2>&1
}

OUT="$(run_check "$CHECK" --notice)"
assert_empty "cold cache notice is silent" "$OUT"

OUT="$(run_check "$CHECK")"
assert_eq "sync check finds the newer tag" "$(printf '%s' "$OUT" | grep -c '0\.4\.0 available')" "1"
assert_eq "sync check names the installed version" "$(printf '%s' "$OUT" | grep -c 'you have 0\.3\.1')" "1"
assert_eq "cache has two lines" "$(wc -l < "$CACHE/version-check" | tr -d ' ')" "2"
assert_eq "cache records the latest" "$(sed -n 2p "$CACHE/version-check")" "0.4.0"

OUT="$(run_check "$CHECK" --notice)"
assert_eq "warm cache notice fires" "$(printf '%s' "$OUT" | grep -c '0\.4\.0 available')" "1"
assert_eq "notice suggests git pull for a checkout" "$(printf '%s' "$OUT" | grep -c 'git -C')" "1"

OUT="$(run_check env TOWER_NO_VERSION_CHECK=1 "$CHECK" --notice)"
assert_empty "opt-out silences notice mode" "$OUT"
OUT="$(run_check env TOWER_NO_VERSION_CHECK=1 "$CHECK")"
assert_empty "opt-out silences sync mode" "$OUT"

printf '%s\n0.3.1\n' "$(date +%s)" > "$CACHE/version-check"
OUT="$(run_check "$CHECK" --notice)"
assert_empty "no notice when cache says current" "$OUT"

printf '%s\n0.2.0\n' "$(date +%s)" > "$CACHE/version-check"
OUT="$(run_check "$CHECK" --notice)"
assert_empty "no notice when cache is older than installed" "$OUT"

printf 'garbage\n' > "$CACHE/version-check"
OUT="$(run_check "$CHECK" --notice)"
assert_empty "malformed cache is silent" "$OUT"
assert_status "malformed cache still exits 0" \
  "$(run_check "$CHECK" --notice >/dev/null 2>&1; echo $?)" "0"

rm -f "$CACHE/version-check"
mkdir -p "$CACHE/refresh.lock"
run_check "$CHECK" --notice >/dev/null 2>&1
sleep 1
assert_false "held lock suppresses the refresh" test -f "$CACHE/version-check"
rmdir "$CACHE/refresh.lock"

assert_status "unreachable remote still exits 0" \
  "$(env TOWER_ROOT="$FAKE_ROOT" TOWER_VERSION_REMOTE="$TMP/nope" TOWER_CACHE_DIR="$TMP/cache2" \
       HOME="$TMP/fakehome" "$CHECK" >/dev/null 2>&1; echo $?)" "0"
OUT="$(env TOWER_ROOT="$FAKE_ROOT" TOWER_VERSION_REMOTE="$TMP/nope" TOWER_CACHE_DIR="$TMP/cache3" \
         HOME="$TMP/fakehome" "$CHECK" --notice 2>&1)"
assert_empty "unreachable remote prints nothing in notice mode" "$OUT"

BROKEN="$TMP/broken"
mkdir -p "$BROKEN/.claude-plugin" "$BROKEN/lib"
cp "$ROOT/lib/tower-semver.sh" "$ROOT/lib/tower-meta.sh" "$BROKEN/lib/"
printf 'not json' > "$BROKEN/.claude-plugin/plugin.json"
assert_status "unparseable manifest still exits 0" \
  "$(env TOWER_ROOT="$BROKEN" TOWER_VERSION_REMOTE="$REMOTE" TOWER_CACHE_DIR="$TMP/cache4" \
       HOME="$TMP/fakehome" "$CHECK" >/dev/null 2>&1; echo $?)" "0"

PLUGIN_ROOT="$TMP/fakehome/.claude/plugins/cache/tower/tower/0.3.1"
mkdir -p "$PLUGIN_ROOT/.claude-plugin" "$PLUGIN_ROOT/lib"
printf '{"name":"tower","version":"0.3.1"}' > "$PLUGIN_ROOT/.claude-plugin/plugin.json"
cp "$ROOT/lib/tower-semver.sh" "$ROOT/lib/tower-meta.sh" "$PLUGIN_ROOT/lib/"
OUT="$(env TOWER_ROOT="$PLUGIN_ROOT" TOWER_VERSION_REMOTE="$REMOTE" TOWER_CACHE_DIR="$TMP/cache5" \
         HOME="$TMP/fakehome" "$CHECK" 2>&1)"
assert_eq "plugin install suggests /plugin update" \
  "$(printf '%s' "$OUT" | grep -c '/plugin update tower@tower')" "1"

summary
