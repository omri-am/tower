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

next_cache() { mktemp -d "$TMP/cache-XXXXXX"; }

run_check() {
  local cache="$1"; shift
  env TOWER_ROOT="$FAKE_ROOT" TOWER_VERSION_REMOTE="$REMOTE" TOWER_CACHE_DIR="$cache" \
      HOME="$TMP/fakehome" "$@" 2>&1
}

wait_for_unlock() {
  local cache="$1" i=0
  while [ "$i" -lt 50 ]; do
    [ ! -d "$cache/refresh.lock" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

CACHE="$(next_cache)"
OUT="$(run_check "$CACHE" "$CHECK" --notice)"
assert_empty "cold cache notice is silent" "$OUT"
assert_true "cold-cache background refresh releases its lock" wait_for_unlock "$CACHE"
assert_eq "cold-cache background refresh populates the cache" \
  "$(sed -n 2p "$CACHE/version-check" 2>/dev/null)" "0.4.0"

CACHE="$(next_cache)"
OUT="$(run_check "$CACHE" "$CHECK")"
assert_eq "sync check finds the newer tag" "$(printf '%s' "$OUT" | grep -c '0\.4\.0 available')" "1"
assert_eq "sync check names the installed version" "$(printf '%s' "$OUT" | grep -c 'you have 0\.3\.1')" "1"
assert_eq "cache has two lines" "$(wc -l < "$CACHE/version-check" | tr -d ' ')" "2"
assert_eq "cache records the latest" "$(sed -n 2p "$CACHE/version-check")" "0.4.0"

CACHE="$(next_cache)"
printf '%s\n0.4.0\n' "$(date +%s)" > "$CACHE/version-check"
OUT="$(run_check "$CACHE" "$CHECK" --notice)"
assert_eq "warm cache notice fires" "$(printf '%s' "$OUT" | grep -c '0\.4\.0 available')" "1"
assert_eq "notice suggests git pull for a checkout" "$(printf '%s' "$OUT" | grep -c 'git -C')" "1"

CACHE="$(next_cache)"
OUT="$(run_check "$CACHE" env TOWER_NO_VERSION_CHECK=1 "$CHECK" --notice)"
assert_empty "opt-out silences notice mode" "$OUT"
CACHE="$(next_cache)"
OUT="$(run_check "$CACHE" env TOWER_NO_VERSION_CHECK=1 "$CHECK")"
assert_empty "opt-out silences sync mode" "$OUT"

CACHE="$(next_cache)"
printf '%s\n0.3.1\n' "$(date +%s)" > "$CACHE/version-check"
OUT="$(run_check "$CACHE" "$CHECK" --notice)"
assert_empty "no notice when cache says current" "$OUT"

CACHE="$(next_cache)"
printf '%s\n0.2.0\n' "$(date +%s)" > "$CACHE/version-check"
OUT="$(run_check "$CACHE" "$CHECK" --notice)"
assert_empty "no notice when cache is older than installed" "$OUT"

CACHE="$(next_cache)"
printf 'garbage\n' > "$CACHE/version-check"
OUT="$(run_check "$CACHE" "$CHECK" --notice)"
assert_empty "malformed cache is silent" "$OUT"
assert_status "malformed cache still exits 0" \
  "$(run_check "$CACHE" "$CHECK" --notice >/dev/null 2>&1; echo $?)" "0"

CACHE="$(next_cache)"
mkdir -p "$CACHE/refresh.lock"
run_check "$CACHE" "$CHECK" --notice >/dev/null 2>&1
WAITED=0
while [ "$WAITED" -lt 10 ]; do
  [ -f "$CACHE/version-check" ] && break
  sleep 0.1
  WAITED=$((WAITED + 1))
done
assert_false "held lock suppresses the refresh" test -f "$CACHE/version-check"
rmdir "$CACHE/refresh.lock"

CACHE="$(next_cache)"
mkdir -p "$CACHE/refresh.lock"
OUT="$(run_check "$CACHE" "$CHECK")"
assert_eq "sync mode refreshes even when the stampede lock is held" \
  "$(printf '%s' "$OUT" | grep -c '0\.4\.0 available')" "1"
rmdir "$CACHE/refresh.lock" 2>/dev/null || true

CACHE="$(next_cache)"
assert_status "unreachable remote still exits 0" \
  "$(env TOWER_ROOT="$FAKE_ROOT" TOWER_VERSION_REMOTE="$TMP/nope" TOWER_CACHE_DIR="$CACHE" \
       HOME="$TMP/fakehome" "$CHECK" >/dev/null 2>&1; echo $?)" "0"
CACHE="$(next_cache)"
OUT="$(env TOWER_ROOT="$FAKE_ROOT" TOWER_VERSION_REMOTE="$TMP/nope" TOWER_CACHE_DIR="$CACHE" \
         HOME="$TMP/fakehome" "$CHECK" --notice 2>&1)"
assert_empty "unreachable remote prints nothing in notice mode" "$OUT"

BROKEN="$TMP/broken"
mkdir -p "$BROKEN/.claude-plugin" "$BROKEN/lib"
cp "$ROOT/lib/tower-semver.sh" "$ROOT/lib/tower-meta.sh" "$BROKEN/lib/"
printf 'not json' > "$BROKEN/.claude-plugin/plugin.json"
CACHE="$(next_cache)"
assert_status "unparseable manifest still exits 0" \
  "$(env TOWER_ROOT="$BROKEN" TOWER_VERSION_REMOTE="$REMOTE" TOWER_CACHE_DIR="$CACHE" \
       HOME="$TMP/fakehome" "$CHECK" >/dev/null 2>&1; echo $?)" "0"

PLUGIN_ROOT="$TMP/fakehome/.claude/plugins/cache/tower/tower/0.3.1"
mkdir -p "$PLUGIN_ROOT/.claude-plugin" "$PLUGIN_ROOT/lib"
printf '{"name":"tower","version":"0.3.1"}' > "$PLUGIN_ROOT/.claude-plugin/plugin.json"
cp "$ROOT/lib/tower-semver.sh" "$ROOT/lib/tower-meta.sh" "$PLUGIN_ROOT/lib/"
CACHE="$(next_cache)"
OUT="$(env TOWER_ROOT="$PLUGIN_ROOT" TOWER_VERSION_REMOTE="$REMOTE" TOWER_CACHE_DIR="$CACHE" \
         HOME="$TMP/fakehome" "$CHECK" 2>&1)"
assert_eq "plugin install suggests /plugin update" \
  "$(printf '%s' "$OUT" | grep -c '/plugin update tower@tower')" "1"

summary
