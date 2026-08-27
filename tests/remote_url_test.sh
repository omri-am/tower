#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"

CHECK="$ROOT/bin/tower-version-check"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_plugin_root() {
  local dir="$1" version="$2"
  mkdir -p "$dir/.claude-plugin" "$dir/lib" "$dir/bin"
  printf '{"name":"tower","version":"%s"}' "$version" > "$dir/.claude-plugin/plugin.json"
  cp "$ROOT/lib/tower-semver.sh" "$ROOT/lib/tower-meta.sh" "$dir/lib/"
  cp "$CHECK" "$dir/bin/"
}

make_tagged_repo() {
  local dir="$1"; shift
  git init -q "$dir"
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  local tag
  for tag in "$@"; do git -C "$dir" tag "$tag"; done
}

make_marketplace_clone() {
  local dir="$1" origin="$2"
  git init -q "$dir"
  git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$dir" remote add origin "$origin"
}

next_cache() { mktemp -d "$TMP/cache-XXXXXX"; }

HOME_A="$TMP/home-a"
PLUGIN_ROOT_A="$TMP/plugin-root-a"
make_plugin_root "$PLUGIN_ROOT_A" 0.3.1
REMOTE_A="$TMP/remote-a"
make_tagged_repo "$REMOTE_A" v0.3.1 v0.9.0
mkdir -p "$HOME_A/.claude/plugins/marketplaces"
make_marketplace_clone "$HOME_A/.claude/plugins/marketplaces/tower" "$REMOTE_A"
CACHE_A="$(next_cache)"
OUT_A="$(env HOME="$HOME_A" TOWER_ROOT="$PLUGIN_ROOT_A" TOWER_CACHE_DIR="$CACHE_A" \
    "$PLUGIN_ROOT_A/bin/tower-version-check" 2>&1)"
assert_eq "marketplace clone present: sync mode reports the tag from its origin remote" \
  "$(printf '%s' "$OUT_A" | grep -c '0\.9\.0 available')" "1"

FAKE_CHECKOUT_B="$TMP/checkout-b"
make_plugin_root "$FAKE_CHECKOUT_B" 0.3.1
git init -q "$FAKE_CHECKOUT_B"
git -C "$FAKE_CHECKOUT_B" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
REMOTE_B="$TMP/remote-b"
make_tagged_repo "$REMOTE_B" v0.3.1 v0.7.0
git -C "$FAKE_CHECKOUT_B" remote add origin "$REMOTE_B"
HOME_B="$TMP/home-b"
CACHE_B="$(next_cache)"
OUT_B="$(env HOME="$HOME_B" TOWER_ROOT="$FAKE_CHECKOUT_B" TOWER_CACHE_DIR="$CACHE_B" \
    "$FAKE_CHECKOUT_B/bin/tower-version-check" 2>&1)"
assert_eq "no marketplace clone, ROOT is a git repo: sync mode falls through to ROOT's own origin" \
  "$(printf '%s' "$OUT_B" | grep -c '0\.7\.0 available')" "1"

PLUGIN_ROOT_C="$TMP/plugin-root-c"
make_plugin_root "$PLUGIN_ROOT_C" 0.3.1
HOME_C="$TMP/home-c"
CACHE_C="$(next_cache)"
OUT_C="$(env HOME="$HOME_C" TOWER_ROOT="$PLUGIN_ROOT_C" TOWER_CACHE_DIR="$CACHE_C" \
    "$PLUGIN_ROOT_C/bin/tower-version-check" 2>&1)"
assert_empty "neither marketplace clone nor a git ROOT: sync mode is silent" "$OUT_C"
assert_status "neither marketplace clone nor a git ROOT: sync mode still exits 0" \
  "$(env HOME="$HOME_C" TOWER_ROOT="$PLUGIN_ROOT_C" TOWER_CACHE_DIR="$CACHE_C" \
      "$PLUGIN_ROOT_C/bin/tower-version-check" >/dev/null 2>&1; echo $?)" "0"

NOJQ="$TMP/nojq"
mkdir -p "$NOJQ"
for TOOL in bash basename dirname sed mkdir date find rmdir cut tr awk mv head ls tail sort git readlink; do
  TOOLPATH="$(type -P "$TOOL" 2>/dev/null)"
  [ -n "$TOOLPATH" ] && ln -sf "$TOOLPATH" "$NOJQ/$TOOL"
done
CACHE_D="$(next_cache)"
OUT_D="$(env HOME="$HOME_A" TOWER_ROOT="$PLUGIN_ROOT_A" TOWER_CACHE_DIR="$CACHE_D" PATH="$NOJQ" \
    "$PLUGIN_ROOT_A/bin/tower-version-check" 2>&1)"
assert_eq "jq unreachable, plugin-style ROOT that is not a git repo: marketplace clone still yields a usable URL" \
  "$(printf '%s' "$OUT_D" | grep -c '0\.9\.0 available')" "1"

summary
