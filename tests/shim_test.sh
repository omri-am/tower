#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"

make_root() {
  local dir="$1" version="$2"
  mkdir -p "$dir/bin" "$dir/lib" "$dir/.claude-plugin" "$dir/skills/tower-orchestrator"
  printf '{"name":"tower","version":"%s"}' "$version" > "$dir/.claude-plugin/plugin.json"
  cp "$ROOT/lib/tower-semver.sh" "$ROOT/lib/tower-meta.sh" "$dir/lib/"
  cp "$ROOT/bin/tower-version-check" "$dir/bin/"
  printf '#!/usr/bin/env bash\necho "locate from %s"\n' "$version" > "$dir/bin/tower-locate"
  printf '#!/usr/bin/env bash\necho "init %s args:$*"\n' "$version" > "$dir/bin/tower-init"
  printf '#!/usr/bin/env bash\nexit 42\n' > "$dir/bin/tower-watch"
  chmod +x "$dir/bin/"*
}

OLD="$FAKE_HOME/.claude/plugins/cache/tower/tower/0.9.0"
NEW="$FAKE_HOME/.claude/plugins/cache/tower/tower/0.10.0"
DEV="$TMP/checkout"
make_root "$OLD" 0.9.0
make_root "$NEW" 0.10.0
make_root "$DEV" 9.9.9

LIBEXEC="$TMP/libexec"
BINDIR="$TMP/bin"
cp "$ROOT/bin/tower-shim" "$DEV/bin/tower-shim"
cp "$ROOT/bin/tower-bootstrap" "$DEV/bin/tower-bootstrap"
chmod +x "$DEV/bin/tower-shim" "$DEV/bin/tower-bootstrap"
env TOWER_BIN_DIR="$BINDIR" TOWER_LIBEXEC_DIR="$LIBEXEC" HOME="$FAKE_HOME" \
    "$DEV/bin/tower-bootstrap" >/dev/null 2>&1

assert_true "shim copied to libexec" test -x "$LIBEXEC/tower-shim"
assert_true "tower-init linked" test -L "$BINDIR/tower-init"
assert_true "tower-locate linked" test -L "$BINDIR/tower-locate"
assert_true "tower-bootstrap linked" test -L "$BINDIR/tower-bootstrap"
assert_eq "links point at the shim copy" "$(readlink "$BINDIR/tower-init")" "$LIBEXEC/tower-shim"

env TOWER_BIN_DIR="$BINDIR" TOWER_LIBEXEC_DIR="$LIBEXEC" HOME="$FAKE_HOME" \
    "$DEV/bin/tower-bootstrap" >/dev/null 2>&1
assert_status "bootstrap is idempotent" "$?" "0"

run_link() {
  local cmd="$1"; shift
  env HOME="$FAKE_HOME" TOWER_NO_VERSION_CHECK=1 "$@" "$BINDIR/$cmd" 2>&1
}

assert_eq "registry-free resolution picks the highest cache version" \
  "$(run_link tower-locate)" "locate from 0.10.0"

REG="$FAKE_HOME/.claude/plugins/installed_plugins.json"
mkdir -p "$(dirname "$REG")"
printf '{"version":2,"plugins":{"tower@tower":[{"installPath":"%s","version":"0.9.0"}]}}\n' "$OLD" > "$REG"
if command -v jq >/dev/null 2>&1; then
  assert_eq "registry wins over the cache glob" "$(run_link tower-locate)" "locate from 0.9.0"
fi

printf '{"version":2,"plugins":{"tower@tower":[{"installPath":"%s/gone","version":"0.9.0"}]}}\n' "$OLD" > "$REG"
assert_eq "dead registry path falls through to the cache glob" \
  "$(run_link tower-locate)" "locate from 0.10.0"

assert_eq "TOWER_ROOT overrides everything" \
  "$(run_link tower-locate env TOWER_ROOT="$DEV")" "locate from 9.9.9"

assert_eq "arguments reach the target" \
  "$(env HOME="$FAKE_HOME" TOWER_NO_VERSION_CHECK=1 TOWER_ROOT="$DEV" "$BINDIR/tower-init" a b 2>&1)" \
  "init 9.9.9 args:a b"

env HOME="$FAKE_HOME" TOWER_NO_VERSION_CHECK=1 TOWER_ROOT="$DEV" "$BINDIR/tower-watch" >/dev/null 2>&1
assert_status "exit status is preserved" "$?" "42"

env HOME="$TMP/empty" TOWER_NO_VERSION_CHECK=1 "$BINDIR/tower-init" >/dev/null 2>&1
assert_status "unresolvable root exits 127" "$?" "127"

NOT_TOWER="$TMP/nottower"
mkdir -p "$NOT_TOWER/bin"
printf '#!/usr/bin/env bash\necho wrong\n' > "$NOT_TOWER/bin/tower-locate"
chmod +x "$NOT_TOWER/bin/tower-locate"
env HOME="$TMP/empty" TOWER_NO_VERSION_CHECK=1 TOWER_ROOT="$NOT_TOWER" "$BINDIR/tower-locate" >/dev/null 2>&1
assert_status "a directory without skills is not a tower root" "$?" "127"

REMOTE="$TMP/remote"
git init -q "$REMOTE"
git -C "$REMOTE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$REMOTE" tag v99.0.0
CACHE="$TMP/shimcache"
env HOME="$FAKE_HOME" TOWER_ROOT="$DEV" TOWER_VERSION_REMOTE="$REMOTE" TOWER_CACHE_DIR="$CACHE" \
    "$DEV/bin/tower-version-check" >/dev/null 2>&1
OUT="$(env HOME="$FAKE_HOME" TOWER_ROOT="$DEV" TOWER_VERSION_REMOTE="$REMOTE" TOWER_CACHE_DIR="$CACHE" \
        "$BINDIR/tower-locate" 2>&1)"
assert_eq "shim prints the notice on stderr before running" \
  "$(printf '%s' "$OUT" | grep -c '99\.0\.0 available')" "1"
assert_eq "target stdout is unpolluted" \
  "$(env HOME="$FAKE_HOME" TOWER_ROOT="$DEV" TOWER_VERSION_REMOTE="$REMOTE" TOWER_CACHE_DIR="$CACHE" \
       "$BINDIR/tower-locate" 2>/dev/null)" "locate from 9.9.9"

summary
