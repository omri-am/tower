#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"

HOOK="$ROOT/hooks/tower-version-notice.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REMOTE="$TMP/remote"
git init -q "$REMOTE"
git -C "$REMOTE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REMOTE" tag v99.1.0

CACHE="$TMP/cache"
mkdir -p "$CACHE"
printf '%s\n99.1.0\n' "$(date +%s)" > "$CACHE/version-check"

run_hook() {
  env HOME="$TMP/home" CLAUDE_PLUGIN_ROOT="$ROOT" TOWER_CACHE_DIR="$CACHE" \
      TOWER_VERSION_REMOTE="$REMOTE" "$@" bash "$HOOK" 2>/dev/null
}

OUT="$(cd "$TMP" && run_hook env X=1)"
assert_eq "hook emits SessionStart json" "$(printf '%s' "$OUT" | grep -c '"hookEventName":"SessionStart"')" "1"
assert_eq "hook carries the notice text" "$(printf '%s' "$OUT" | grep -c '99\.1\.0 available')" "1"
assert_eq "hook output is one line" "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "1"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "hook output is valid json" \
    "$(printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin); print("ok")')" "ok"
fi

printf '%s\n0.0.1\n' "$(date +%s)" > "$CACHE/version-check"
OUT="$(cd "$TMP" && run_hook env X=1)"
assert_empty "no update means no output" "$OUT"

OUT="$(cd "$TMP" && run_hook env TOWER_NO_VERSION_CHECK=1)"
assert_empty "opt-out silences the hook" "$OUT"

OUT="$(cd "$TMP" && env HOME="$TMP/home" CLAUDE_PLUGIN_ROOT="$TMP/gone" bash "$HOOK" 2>/dev/null)"
assert_empty "bad plugin root produces no output" "$OUT"
assert_status "bad plugin root still exits 0" \
  "$(cd "$TMP" && env HOME="$TMP/home" CLAUDE_PLUGIN_ROOT="$TMP/gone" bash "$HOOK" >/dev/null 2>&1; echo $?)" "0"

assert_eq "hooks.json registers exactly one event" \
  "$(grep -c '"SessionStart"' "$ROOT/hooks/hooks.json")" "1"
assert_eq "hooks.json uses CLAUDE_PLUGIN_ROOT" \
  "$(grep -c 'CLAUDE_PLUGIN_ROOT' "$ROOT/hooks/hooks.json")" "1"
if command -v python3 >/dev/null 2>&1; then
  assert_eq "hooks.json is valid json" \
    "$(python3 -c 'import json;json.load(open("'"$ROOT"'/hooks/hooks.json"));print("ok")')" "ok"
fi

summary
