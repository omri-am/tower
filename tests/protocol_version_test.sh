#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROJECT="$TMP/project"
mkdir -p "$PROJECT"
git init -q "$PROJECT"
git -C "$PROJECT" config user.email t@t
git -C "$PROJECT" config user.name t
git -C "$PROJECT" commit -q --allow-empty -m init

env HOME="$TMP/home" "$ROOT/bin/tower-init" "$PROJECT" >/dev/null 2>&1
assert_true ".tower/version written" test -f "$PROJECT/.tower/version"
assert_eq "records the tower version" \
  "$(sed -n 1p "$PROJECT/.tower/version")" "tower $(. "$ROOT/lib/tower-meta.sh"; tower_version "$ROOT")"
assert_eq "records the protocol version" \
  "$(sed -n 2p "$PROJECT/.tower/version")" "protocol $(cat "$ROOT/PROTOCOL_VERSION")"

CACHE="$TMP/cache"
printf '%s\n%s\n' "$(date +%s)" "$(. "$ROOT/lib/tower-meta.sh"; tower_version "$ROOT")" > "$TMP/seed"
mkdir -p "$CACHE"
cp "$TMP/seed" "$CACHE/version-check"

run_in_project() {
  ( cd "$PROJECT" && env HOME="$TMP/home" TOWER_CACHE_DIR="$CACHE" \
      TOWER_VERSION_REMOTE="$TMP/nope" "$ROOT/bin/tower-version-check" "$@" 2>&1 )
}

OUT="$(run_in_project --notice)"
assert_empty "matching protocol is silent" "$OUT"

printf 'tower 0.0.1\nprotocol 99\n' > "$PROJECT/.tower/version"
OUT="$(run_in_project --notice)"
assert_eq "protocol mismatch warns" "$(printf '%s' "$OUT" | grep -c 'protocol 99')" "1"
assert_eq "mismatch names this tower's protocol" \
  "$(printf '%s' "$OUT" | grep -c "protocol $(cat "$ROOT/PROTOCOL_VERSION")")" "1"
OUT="$(run_in_project)"
assert_eq "mismatch warns in sync mode too" "$(printf '%s' "$OUT" | grep -c 'protocol 99')" "1"

printf 'tower 0.0.1\n' > "$PROJECT/.tower/version"
OUT="$(run_in_project --notice)"
assert_empty "missing protocol line is silent" "$OUT"

rm -f "$PROJECT/.tower/version"
OUT="$(run_in_project --notice)"
assert_empty "missing version file is silent" "$OUT"

OUT="$( cd "$TMP" && env HOME="$TMP/home" TOWER_CACHE_DIR="$CACHE" \
        TOWER_VERSION_REMOTE="$TMP/nope" "$ROOT/bin/tower-version-check" --notice 2>&1 )"
assert_empty "no project located is silent" "$OUT"

summary
