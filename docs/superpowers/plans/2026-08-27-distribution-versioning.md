# Tower Distribution and Version Awareness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship tower as a Claude Code plugin whose shell commands survive version bumps without re-installation, and whose installs tell their user when a newer tower exists.

**Architecture:** The repo becomes its own single-plugin marketplace, so Claude Code owns install and update of `skills/`, `hooks/` and `templates/`. Shell commands reach the versioned plugin cache through one copied resolver shim that looks up the live install path at call time, the way `rbenv` shims do. A single cached version-check script feeds two thin surfaces — a stderr line before every shimmed command, and SessionStart `additionalContext` inside Claude sessions.

**Tech Stack:** bash (macOS first, no GNU-only flags), git plumbing (`git ls-remote`), Claude Code plugin manifests, plugin hooks. `jq` is optional everywhere with a documented fallback. No test framework — plain bash asserts.

**Spec:** `docs/superpowers/specs/2026-08-27-distribution-versioning-design.md`

## Global Constraints

- Target platform is macOS first. Do not use `sort -V`, `readlink` without checking, GNU `date -d`, or `grep -P`.
- `jq` must never be required. Every `jq` call needs a working fallback path.
- `bin/tower-locate` stdout must stay byte-identical. It gains no new output on stdout, ever. All notices go to stderr.
- `bin/tower-version-check` always exits 0. No failure mode of it may break a tower command.
- Existing `bin/*` scripts style: `#!/usr/bin/env bash`, `set -euo pipefail`, no comments, messages prefixed with the script name, errors to stderr.
- Tower version lives in exactly one place: `version` in `.claude-plugin/plugin.json`. Git tags mirror it as `vX.Y.Z`.
- Protocol version lives in exactly one place: `PROTOCOL_VERSION` at repo root, a bare integer.
- Marketplace name is `tower`, plugin name is `tower`, so the plugin reference is `tower@tower` and the plugin cache path is `~/.claude/plugins/cache/tower/tower/<version>/`.
- Tests live in `tests/*_test.sh`, use `set -uo pipefail` (never `-e`, it breaks negative assertions), and must not touch the real `$HOME`.
- No automatic pushing and no automatic `.tower/` migration anywhere in this plan.

---

### Task 1: Test harness and semver library

**Files:**
- Create: `tests/lib.sh`
- Create: `tests/run.sh`
- Create: `lib/tower-semver.sh`
- Test: `tests/semver_test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `tests/lib.sh` functions, all usable after `. tests/lib.sh`: `assert_eq <name> <actual> <expected>`, `assert_empty <name> <actual>`, `assert_status <name> <actual_status> <expected_status>`, `assert_true <name> <cmd...>`, `assert_false <name> <cmd...>`, `summary` (prints counts, exits non-zero if any check failed).
  - `lib/tower-semver.sh` functions, usable after `. lib/tower-semver.sh`: `semver_strip <string>` prints the version with a leading `v` and any `-pre`/`+build` suffix removed; `semver_gt <a> <b>` returns 0 when a is strictly newer, 1 when it is not, 2 when either side is unparseable; `semver_max` reads one version per line on stdin and prints the highest, empty string for no valid input.

- [ ] **Step 1: Write the failing test**

Create `tests/semver_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/lib/tower-semver.sh"

assert_eq "strip leading v" "$(semver_strip v1.2.3)" "1.2.3"
assert_eq "strip prerelease" "$(semver_strip 1.2.3-rc1)" "1.2.3"
assert_eq "strip build" "$(semver_strip 1.2.3+abc)" "1.2.3"
assert_eq "strip plain" "$(semver_strip 1.2.3)" "1.2.3"

assert_false "equal is not greater" semver_gt 1.2.3 1.2.3
assert_true  "patch greater" semver_gt 1.2.4 1.2.3
assert_false "patch lesser" semver_gt 1.2.3 1.2.4
assert_true  "minor greater" semver_gt 1.3.0 1.2.9
assert_false "minor lesser" semver_gt 1.2.9 1.3.0
assert_true  "major greater" semver_gt 2.0.0 1.9.9
assert_false "major lesser" semver_gt 1.9.9 2.0.0
assert_true  "short vs long" semver_gt 1.3 1.2.9
assert_false "long vs short" semver_gt 1.2.9 1.3
assert_true  "v prefix both sides" semver_gt v0.4.0 v0.3.1
assert_true  "ten beats nine numerically" semver_gt 0.10.0 0.9.0

assert_status "junk left" "$(semver_gt abc 1.0.0; echo $?)" "2"
assert_status "junk right" "$(semver_gt 1.0.0 abc; echo $?)" "2"
assert_status "empty left" "$(semver_gt "" 1.0.0; echo $?)" "2"

assert_eq "max picks highest" "$(printf '0.1.0\n0.10.0\n0.9.0\n' | semver_max)" "0.10.0"
assert_eq "max strips v" "$(printf 'v1.0.0\nv1.0.1\n' | semver_max)" "1.0.1"
assert_eq "max skips junk" "$(printf 'junk\n1.0.0\n' | semver_max)" "1.0.0"
assert_empty "max of nothing" "$(printf '' | semver_max)"

summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/semver_test.sh`
Expected: FAIL — `tests/lib.sh: No such file or directory`

- [ ] **Step 3: Write the harness**

Create `tests/lib.sh`:

```bash
#!/usr/bin/env bash
TESTS_RUN=0
TESTS_FAILED=0

_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL $1" >&2
}

assert_eq() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" != "$3" ]; then _fail "$1: expected [$3], got [$2]"; fi
}

assert_empty() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -n "$2" ]; then _fail "$1: expected empty, got [$2]"; fi
}

assert_status() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" != "$3" ]; then _fail "$1: expected exit $3, got exit $2"; fi
}

assert_true() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local name="$1"; shift
  if ! "$@"; then _fail "$name: expected success from: $*"; fi
}

assert_false() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local name="$1"; shift
  if "$@"; then _fail "$name: expected failure from: $*"; fi
}

summary() {
  echo "  $TESTS_RUN checks, $TESTS_FAILED failed"
  [ "$TESTS_FAILED" = 0 ]
}
```

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS=0
for T in "$ROOT"/tests/*_test.sh; do
  echo "== $(basename "$T")"
  bash "$T" || STATUS=1
done
if [ "$STATUS" = 0 ]; then echo "tests: all passed"; else echo "tests: FAILURES" >&2; fi
exit "$STATUS"
```

Create `lib/tower-semver.sh`:

```bash
#!/usr/bin/env bash

semver_strip() {
  local v="${1#v}"
  printf '%s' "${v%%[-+]*}"
}

semver_gt() {
  local a b i ap bp
  a="$(semver_strip "${1:-}")"
  b="$(semver_strip "${2:-}")"
  if [ -z "$a" ] || [ -z "$b" ]; then return 2; fi
  case "$a$b" in *[!0-9.]*) return 2 ;; esac
  for i in 1 2 3; do
    ap="$(printf '%s' "$a" | cut -d. -f"$i")"
    bp="$(printf '%s' "$b" | cut -d. -f"$i")"
    ap="${ap:-0}"
    bp="${bp:-0}"
    if [ "$ap" -gt "$bp" ]; then return 0; fi
    if [ "$ap" -lt "$bp" ]; then return 1; fi
  done
  return 1
}

semver_max() {
  local best="" line
  while IFS= read -r line; do
    line="$(semver_strip "$line")"
    if [ -z "$line" ]; then continue; fi
    case "$line" in *[!0-9.]*) continue ;; esac
    if [ -z "$best" ] || semver_gt "$line" "$best"; then best="$line"; fi
  done
  printf '%s' "$best"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x tests/run.sh && bash tests/semver_test.sh`
Expected: PASS — the summary line ends `0 failed`

Then run: `bash tests/run.sh`
Expected: `tests: all passed`

- [ ] **Step 5: Commit**

```bash
git add tests lib
git commit -m "Dependency-free bash test harness and a semver comparison library"
```

---

### Task 2: Plugin manifests, protocol version file, and the skill-namespace note

**Files:**
- Create: `.claude-plugin/marketplace.json`
- Create: `.claude-plugin/plugin.json`
- Create: `PROTOCOL_VERSION`
- Create: `lib/tower-meta.sh`
- Modify: `bin/tower-orchestrate:26`
- Modify: `skills/tower-orchestrator/SKILL.md:97`
- Test: `tests/meta_test.sh`

**Interfaces:**
- Consumes: `lib/tower-semver.sh` from Task 1 (`semver_strip`).
- Produces: `lib/tower-meta.sh` functions, usable after `. lib/tower-meta.sh`: `tower_version <root>` prints the `version` value from `<root>/.claude-plugin/plugin.json`, or empty string if unreadable or unparseable; `tower_protocol_version <root>` prints the integer in `<root>/PROTOCOL_VERSION`, or empty string; `tower_json_string <file> <key>` prints the first string value for `<key>` in `<file>`, using `jq` when available and a `sed` fallback otherwise.

- [ ] **Step 1: Write the failing test**

Create `tests/meta_test.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/lib/tower-meta.sh"

assert_eq "real repo version parses" "$(tower_version "$ROOT" | grep -c '^[0-9][0-9.]*$')" "1"
assert_eq "real repo protocol is an integer" "$(tower_protocol_version "$ROOT" | grep -c '^[0-9][0-9]*$')" "1"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude-plugin"

printf '{\n  "name": "tower",\n  "version": "1.2.3"\n}\n' > "$TMP/.claude-plugin/plugin.json"
assert_eq "version from manifest" "$(tower_version "$TMP")" "1.2.3"

printf '{"version":"9.9.9","name":"tower"}' > "$TMP/.claude-plugin/plugin.json"
assert_eq "version first on one line" "$(tower_version "$TMP")" "9.9.9"

printf 'not json at all' > "$TMP/.claude-plugin/plugin.json"
assert_empty "malformed manifest is empty" "$(tower_version "$TMP")"

rm -f "$TMP/.claude-plugin/plugin.json"
assert_empty "missing manifest is empty" "$(tower_version "$TMP")"

assert_empty "missing protocol file is empty" "$(tower_protocol_version "$TMP")"
printf '4\n' > "$TMP/PROTOCOL_VERSION"
assert_eq "protocol from file" "$(tower_protocol_version "$TMP")" "4"
printf 'abc\n' > "$TMP/PROTOCOL_VERSION"
assert_empty "non-integer protocol is empty" "$(tower_protocol_version "$TMP")"

MANIFEST_VERSION="$(tower_version "$ROOT")"
assert_eq "marketplace names the plugin tower" \
  "$(grep -c '"name": "tower"' "$ROOT/.claude-plugin/marketplace.json")" "2"
assert_eq "orchestrate prompt mentions the namespaced skill" \
  "$(grep -c 'tower:tower-orchestrator' "$ROOT/bin/tower-orchestrate")" "1"
assert_eq "orchestrator skill mentions the namespaced implementor skill" \
  "$(grep -c 'tower:tower-implementor' "$ROOT/skills/tower-orchestrator/SKILL.md")" "1"

summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/meta_test.sh`
Expected: FAIL — `lib/tower-meta.sh: No such file or directory`

- [ ] **Step 3: Write the manifests and the meta library**

Create `.claude-plugin/plugin.json`:

```json
{
  "name": "tower",
  "version": "0.1.0",
  "description": "File-based orchestration for multi-agent development: one orchestrator plans and curates, parallel implementor sessions each execute one task, all durable state is markdown in a git-versioned .tower/ directory.",
  "author": {
    "name": "Omri Amit",
    "email": "omry.amit@gmail.com"
  },
  "homepage": "https://github.com/omri-am/tower",
  "repository": "https://github.com/omri-am/tower",
  "license": "MIT",
  "keywords": [
    "orchestration",
    "multi-agent",
    "worktrees",
    "handoffs"
  ]
}
```

Create `.claude-plugin/marketplace.json`:

```json
{
  "$schema": "https://anthropic.com/claude-code/marketplace.schema.json",
  "name": "tower",
  "description": "File-based multi-agent orchestration for Claude Code.",
  "owner": {
    "name": "Omri Amit",
    "email": "omry.amit@gmail.com"
  },
  "plugins": [
    {
      "name": "tower",
      "source": "./",
      "description": "Orchestrator and implementor roles, the .tower protocol, and the tower shell commands."
    }
  ]
}
```

Create `PROTOCOL_VERSION` containing exactly:

```
1
```

Create `lib/tower-meta.sh`:

```bash
#!/usr/bin/env bash

tower_json_string() {
  local file="$1" key="$2" out=""
  if [ ! -r "$file" ]; then return 0; fi
  if command -v jq >/dev/null 2>&1; then
    out="$(jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null)"
  fi
  if [ -z "$out" ]; then
    out="$(tr -d '\n' < "$file" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  fi
  printf '%s' "$out"
}

tower_version() {
  tower_json_string "${1:-.}/.claude-plugin/plugin.json" version
}

tower_protocol_version() {
  local file="${1:-.}/PROTOCOL_VERSION" out
  if [ ! -r "$file" ]; then return 0; fi
  out="$(tr -d '[:space:]' < "$file")"
  case "$out" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$out"
}
```

The `sed` fallback collapses newlines first so a pretty-printed manifest matches, and takes the first quoted value after the key.

- [ ] **Step 4: Add the skill-namespace note to both prompt sites**

In `bin/tower-orchestrate`, replace line 26 with:

```bash
PROMPT="Invoke the tower-orchestrator skill (listed as tower:tower-orchestrator when tower is installed as a Claude Code plugin) and assume the orchestrator role for this project. Follow the skill fully: run the rehydration ritual including registering your address in .tower/orchestrator, then start the standing loop."
```

In `skills/tower-orchestrator/SKILL.md`, line 97 currently reads:

```
`prompts/T###-prompt.md`: instruct the implementor to follow the tower-implementor skill,
```

Replace it with:

```
`prompts/T###-prompt.md`: instruct the implementor to follow the tower-implementor skill
(listed as `tower:tower-implementor` when tower is installed as a Claude Code plugin),
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash tests/meta_test.sh`
Expected: PASS — the summary line ends `0 failed`

Run: `bash tests/run.sh`
Expected: `tests: all passed`

Run: `python3 -c "import json,sys; [json.load(open(p)) for p in ['.claude-plugin/plugin.json','.claude-plugin/marketplace.json']]; print('json ok')"`
Expected: `json ok`

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin PROTOCOL_VERSION lib/tower-meta.sh tests/meta_test.sh bin/tower-orchestrate skills/tower-orchestrator/SKILL.md
git commit -m "Tower is its own single-plugin marketplace, with a protocol version and namespace-aware skill prompts"
```

---

### Task 3: The version check

**Files:**
- Create: `bin/tower-version-check`
- Test: `tests/version_check_test.sh`

**Interfaces:**
- Consumes: `lib/tower-semver.sh` (`semver_gt`, `semver_max`) and `lib/tower-meta.sh` (`tower_version`) from Tasks 1 and 2.
- Produces: executable `bin/tower-version-check`, exit status always 0.
  - `tower-version-check --notice` prints at most one stderr line, only from cache, and spawns a detached refresh when the cache is older than the TTL. Silent when current, when the cache is absent, and when `TOWER_NO_VERSION_CHECK=1`.
  - `tower-version-check` with no arguments refreshes synchronously and always reports, including `tower: 0.1.0 is current` when up to date.
  - Environment contract, all honoured by both modes: `TOWER_ROOT` (install root override), `TOWER_VERSION_REMOTE` (git remote to query, bypassing marketplace lookup), `TOWER_CACHE_DIR` (cache location, default `${XDG_CACHE_HOME:-$HOME/.cache}/tower`), `TOWER_VERSION_CHECK_TTL` (seconds, default 86400), `TOWER_NO_VERSION_CHECK=1` (silence).
  - Cache file `<cache dir>/version-check` holds exactly two lines: the check epoch, then the latest version seen.

- [ ] **Step 1: Write the failing test**

Create `tests/version_check_test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/version_check_test.sh`
Expected: FAIL — every assertion, because `bin/tower-version-check` does not exist yet (`cp: no such file`).

- [ ] **Step 3: Write the implementation**

Create `bin/tower-version-check`:

```bash
#!/usr/bin/env bash
set -uo pipefail

MODE=notice
case "${1:-}" in
  --notice) MODE=notice ;;
  "") MODE=sync ;;
  *) echo "usage: tower-version-check [--notice]" >&2; exit 0 ;;
esac

if [ "${TOWER_NO_VERSION_CHECK:-0}" = 1 ]; then exit 0; fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${TOWER_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
if [ ! -r "$ROOT/lib/tower-semver.sh" ] || [ ! -r "$ROOT/lib/tower-meta.sh" ]; then exit 0; fi
. "$ROOT/lib/tower-semver.sh"
. "$ROOT/lib/tower-meta.sh"

CACHE_DIR="${TOWER_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/tower}"
CACHE_FILE="$CACHE_DIR/version-check"
LOCK_DIR="$CACHE_DIR/refresh.lock"
TTL="${TOWER_VERSION_CHECK_TTL:-86400}"

LOCAL="$(tower_version "$ROOT")"
if [ -z "$LOCAL" ]; then exit 0; fi

remote_url() {
  if [ -n "${TOWER_VERSION_REMOTE:-}" ]; then printf '%s' "$TOWER_VERSION_REMOTE"; return 0; fi
  local known="$HOME/.claude/plugins/known_marketplaces.json" url=""
  if [ -r "$known" ] && command -v jq >/dev/null 2>&1; then
    url="$(jq -r '.tower.source.url // (if .tower.source.repo then "https://github.com/" + .tower.source.repo + ".git" else empty end)' "$known" 2>/dev/null)"
    if [ "$url" = "null" ]; then url=""; fi
  fi
  if [ -z "$url" ]; then url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"; fi
  printf '%s' "$url"
}

fetch_latest() {
  local url="$1"
  git ls-remote --tags "$url" 'v*' 2>/dev/null \
    | sed -n 's#.*refs/tags/##p' \
    | sed 's/\^{}$//' \
    | semver_max
}

write_cache() {
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  printf '%s\n%s\n' "$(date +%s)" "$1" > "$CACHE_FILE.tmp" 2>/dev/null || return 0
  mv "$CACHE_FILE.tmp" "$CACHE_FILE" 2>/dev/null || return 0
}

cache_epoch() { sed -n 1p "$CACHE_FILE" 2>/dev/null | tr -d '[:space:]'; }
cache_latest() { sed -n 2p "$CACHE_FILE" 2>/dev/null | tr -d '[:space:]'; }

cache_fresh() {
  local then now
  then="$(cache_epoch)"
  case "$then" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ $((now - then)) -lt "$TTL" ]
}

take_lock() {
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 1
  if mkdir "$LOCK_DIR" 2>/dev/null; then return 0; fi
  if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" 2>/dev/null && return 0
  fi
  return 1
}

refresh() {
  local url latest
  url="$(remote_url)"
  if [ -z "$url" ]; then return 0; fi
  latest="$(fetch_latest "$url")"
  if [ -n "$latest" ]; then write_cache "$latest"; fi
}

update_hint() {
  case "$ROOT" in
    "$HOME/.claude/plugins/cache/"*) printf '/plugin update tower@tower' ;;
    *) printf 'git -C %s pull' "$ROOT" ;;
  esac
}

report_if_newer() {
  local latest="$1"
  case "$latest" in ''|*[!0-9.]*) return 0 ;; esac
  if semver_gt "$latest" "$LOCAL"; then
    echo "tower: $latest available (you have $LOCAL) -> $(update_hint)" >&2
  fi
}

if [ "$MODE" = sync ]; then
  if take_lock; then
    refresh
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  LATEST="$(cache_latest)"
  if [ -z "$LATEST" ]; then exit 0; fi
  if semver_gt "$LATEST" "$LOCAL"; then
    report_if_newer "$LATEST"
  else
    echo "tower: $LOCAL is current" >&2
  fi
  exit 0
fi

report_if_newer "$(cache_latest)"

if ! cache_fresh; then
  if take_lock; then
    ( refresh; rmdir "$LOCK_DIR" 2>/dev/null || true ) >/dev/null 2>&1 &
  fi
fi
exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x bin/tower-version-check && bash tests/version_check_test.sh`
Expected: PASS — the summary line ends `0 failed`

Run: `bash tests/run.sh`
Expected: `tests: all passed`

- [ ] **Step 5: Commit**

```bash
git add bin/tower-version-check tests/version_check_test.sh
git commit -m "Cached, non-blocking version check that can never fail a tower command"
```

---

### Task 4: Resolver shim and bootstrap

**Files:**
- Create: `bin/tower-shim`
- Create: `bin/tower-bootstrap`
- Create: `commands/tower-bootstrap.md`
- Test: `tests/shim_test.sh`

**Interfaces:**
- Consumes: `bin/tower-version-check` from Task 3.
- Produces:
  - `bin/tower-shim`, invoked through a symlink named after the command it should run. Resolves the install root in order: `TOWER_ROOT`, then `installed_plugins.json` (jq) or the highest-numbered directory under `$HOME/.claude/plugins/cache/tower/tower/`, then its own `../` when that looks like a tower checkout. Calls `tower-version-check --notice` unless the target is `tower-version-check`, then execs `<root>/bin/<command> "$@"`. Exit 127 with a stderr message when the root cannot be resolved. A directory counts as a root only when it holds both `bin/tower-locate` and `skills/tower-orchestrator`.
  - `bin/tower-bootstrap`, idempotent. Copies `tower-shim` to `${TOWER_LIBEXEC_DIR:-$HOME/.local/libexec}` and symlinks each command in `${TOWER_BIN_DIR:-$HOME/.local/bin}` to that copy.

- [ ] **Step 1: Write the failing test**

Create `tests/shim_test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/shim_test.sh`
Expected: FAIL — `bin/tower-bootstrap` and `bin/tower-shim` do not exist.

- [ ] **Step 3: Write the shim**

Create `bin/tower-shim`:

```bash
#!/usr/bin/env bash
set -uo pipefail

CMD="$(basename "$0")"

is_root() {
  [ -n "${1:-}" ] && [ -x "$1/bin/tower-locate" ] && [ -d "$1/skills/tower-orchestrator" ]
}

from_registry() {
  local reg="$HOME/.claude/plugins/installed_plugins.json" path=""
  if [ -r "$reg" ] && command -v jq >/dev/null 2>&1; then
    path="$(jq -r '.plugins["tower@tower"][]?.installPath // empty' "$reg" 2>/dev/null | tail -1)"
  fi
  printf '%s' "$path"
}

from_cache() {
  local base="$HOME/.claude/plugins/cache/tower/tower" newest=""
  if [ ! -d "$base" ]; then return 0; fi
  newest="$(cd "$base" && ls -1d */ 2>/dev/null | tr -d / | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
  if [ -n "$newest" ]; then printf '%s/%s' "$base" "$newest"; fi
}

from_self() {
  local dir
  dir="$(cd "$(dirname "$0")" && pwd)" || return 0
  printf '%s' "$(cd "$dir/.." && pwd)"
}

ROOT=""
for CANDIDATE in "${TOWER_ROOT:-}" "$(from_registry)" "$(from_cache)" "$(from_self)"; do
  if is_root "$CANDIDATE"; then ROOT="$CANDIDATE"; break; fi
done

if [ -z "$ROOT" ]; then
  echo "tower: cannot resolve the tower install - run tower-bootstrap again, or set TOWER_ROOT" >&2
  exit 127
fi

TARGET="$ROOT/bin/$CMD"
if [ ! -x "$TARGET" ]; then
  echo "tower: $CMD is not a command in $ROOT/bin" >&2
  exit 127
fi

if [ "$CMD" != "tower-version-check" ] && [ -x "$ROOT/bin/tower-version-check" ]; then
  TOWER_ROOT="$ROOT" "$ROOT/bin/tower-version-check" --notice || true
fi

exec "$TARGET" "$@"
```

`from_self` deliberately resolves only the shim's own directory without following symlinks: when the shim is the copy in `~/.local/libexec` it will not look like a tower root and the candidate is rejected by `is_root`, which is the intended outcome. It succeeds only when `tower-shim` is executed from inside a real checkout's `bin/`.

- [ ] **Step 4: Write the bootstrap and the slash command**

Create `bin/tower-bootstrap`:

```bash
#!/usr/bin/env bash
set -euo pipefail

TOWER_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${TOWER_BIN_DIR:-$HOME/.local/bin}"
LIBEXEC_DIR="${TOWER_LIBEXEC_DIR:-$HOME/.local/libexec}"
COMMANDS="tower-init tower-orchestrate tower-dispatch tower-watch tower-learnings tower-pr-wait tower-notify tower-locate tower-version-check tower-bootstrap"

mkdir -p "$BIN_DIR" "$LIBEXEC_DIR"
install -m 0755 "$TOWER_HOME/bin/tower-shim" "$LIBEXEC_DIR/tower-shim"
for CMD in $COMMANDS; do
  ln -sfn "$LIBEXEC_DIR/tower-shim" "$BIN_DIR/$CMD"
done

echo "tower-bootstrap: shim installed at $LIBEXEC_DIR/tower-shim"
echo "tower-bootstrap: linked $(printf '%s\n' $COMMANDS | wc -l | tr -d ' ') commands into $BIN_DIR"
case ":$PATH:" in
  *":$BIN_DIR:"*) echo "tower-bootstrap: $BIN_DIR already on PATH" ;;
  *) echo "tower-bootstrap: add to PATH -> export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
```

Create `commands/tower-bootstrap.md`:

```markdown
---
description: Link tower's shell commands into ~/.local/bin through the resolver shim
allowed-tools: Bash
---

Run `"${CLAUDE_PLUGIN_ROOT}/bin/tower-bootstrap"` with the Bash tool and show the user its
output verbatim. If the output asks for a PATH line, tell the user to add that line to their
shell profile; do not edit their profile yourself. Do not re-run the command more than once.
```

- [ ] **Step 5: Run test to verify it passes**

Run: `chmod +x bin/tower-shim bin/tower-bootstrap && bash tests/shim_test.sh`
Expected: PASS — the summary line ends `0 failed`

Run: `bash tests/run.sh`
Expected: `tests: all passed`

- [ ] **Step 6: Commit**

```bash
git add bin/tower-shim bin/tower-bootstrap commands tests/shim_test.sh
git commit -m "Resolver shim and bootstrap: shell commands follow plugin updates without relinking"
```

---

### Task 5: Protocol version recorded and compared

**Files:**
- Modify: `bin/tower-init` (after the `touch ... .gitkeep` line, before the sidecar branch)
- Modify: `bin/tower-version-check` (add the protocol comparison before the final `exit 0` of each mode)
- Modify: `PROTOCOL.md`
- Test: `tests/protocol_version_test.sh`

**Interfaces:**
- Consumes: `tower_version` and `tower_protocol_version` from Task 2, `bin/tower-locate` (existing, called by absolute path).
- Produces: `.tower/version` written by `tower-init`, exactly two lines — `tower <version>` then `protocol <integer>`. `tower-version-check` gains one additional stderr line on protocol mismatch, in both modes, worded `tower: .tower/ was written for protocol <n>, this tower speaks protocol <m> - re-read .tower/PROTOCOL.md before continuing`.

- [ ] **Step 1: Write the failing test**

Create `tests/protocol_version_test.sh`:

```bash
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

BEFORE="$( cd "$PROJECT" && "$ROOT/bin/tower-locate" 2>/dev/null )"
AFTER="$( cd "$PROJECT" && env TOWER_NO_VERSION_CHECK=1 "$ROOT/bin/tower-locate" 2>/dev/null )"
assert_eq "tower-locate stdout is unchanged by the check" "$BEFORE" "$AFTER"

summary
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/protocol_version_test.sh`
Expected: FAIL — `.tower/version written` fails first, then every protocol assertion.

- [ ] **Step 3: Write `.tower/version` from tower-init**

In `bin/tower-init`, immediately after the existing `touch "$TARGET/.tower/tasks/.gitkeep" ...` line, insert:

```bash
. "$TOWER_ROOT/lib/tower-meta.sh"
printf 'tower %s\nprotocol %s\n' \
  "$(tower_version "$TOWER_ROOT")" "$(tower_protocol_version "$TOWER_ROOT")" \
  > "$TARGET/.tower/version"
```

- [ ] **Step 4: Add the protocol comparison to tower-version-check**

In `bin/tower-version-check`, add this function after `report_if_newer`:

```bash
report_protocol_mismatch() {
  local mine theirs project located
  mine="$(tower_protocol_version "$ROOT")"
  if [ -z "$mine" ]; then return 0; fi
  located="$("$ROOT/bin/tower-locate" --quiet 2>/dev/null || true)"
  project="$(printf '%s\n' "$located" | sed -n 1p)"
  if [ -z "$project" ] || [ ! -r "$project/.tower/version" ]; then return 0; fi
  theirs="$(sed -n 's/^protocol[[:space:]]*//p' "$project/.tower/version" | tr -d '[:space:]')"
  case "$theirs" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$theirs" != "$mine" ]; then
    echo "tower: .tower/ was written for protocol $theirs, this tower speaks protocol $mine - re-read .tower/PROTOCOL.md before continuing" >&2
  fi
}
```

Then call it in both modes. In the `if [ "$MODE" = sync ]` block, insert `report_protocol_mismatch` immediately before its `exit 0`, and also before the earlier `if [ -z "$LATEST" ]; then exit 0; fi` guard so a missing cache does not skip it — replace that guard with:

```bash
  LATEST="$(cache_latest)"
  if [ -n "$LATEST" ]; then
    if semver_gt "$LATEST" "$LOCAL"; then
      report_if_newer "$LATEST"
    else
      echo "tower: $LOCAL is current" >&2
    fi
  fi
  report_protocol_mismatch
  exit 0
```

In notice mode, add `report_protocol_mismatch` immediately after the `report_if_newer "$(cache_latest)"` line.

Note the recursion hazard this avoids: `tower-locate` is called as `"$ROOT/bin/tower-locate"`, never through PATH. A shimmed `tower-locate` would call `tower-version-check --notice`, which would call `tower-locate` again, and so on without termination. Do not change this call to a bare `tower-locate`.

- [ ] **Step 5: Document the rule in PROTOCOL.md**

Append this section to `PROTOCOL.md`:

````markdown
## Protocol version

`PROTOCOL_VERSION` in the tower checkout holds a single integer, bumped only when the format
of a card, handoff, learnings entry or design file changes in a way an older session
misreads. It is not the tower version and does not move when a feature ships.

`tower-init` records both numbers in `.tower/version`:

```
tower 0.1.0
protocol 1
```

`tower-version-check` compares the recorded protocol integer against the running tower's and
warns on mismatch. Nothing migrates automatically: a wrong migration corrupts the audit
trail, which is worse than a warning a human acts on. On a mismatch, re-read
`.tower/PROTOCOL.md` — the copy embedded in the project — before trusting any card format.
````

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/protocol_version_test.sh`
Expected: PASS — the summary line ends `0 failed`

Run: `bash tests/run.sh`
Expected: `tests: all passed`

- [ ] **Step 7: Commit**

```bash
git add bin/tower-init bin/tower-version-check PROTOCOL.md tests/protocol_version_test.sh
git commit -m "Projects record the protocol they were scaffolded for, and a mismatch warns without migrating"
```

---

### Task 6: SessionStart notice hook

**Files:**
- Create: `hooks/hooks.json`
- Create: `hooks/tower-version-notice.sh`
- Modify: `hooks/README.md`
- Test: `tests/hook_notice_test.sh`

**Interfaces:**
- Consumes: `bin/tower-version-check --notice` from Tasks 3 and 5.
- Produces: `hooks/tower-version-notice.sh`, which prints nothing and exits 0 when there is no notice, and otherwise prints one line of JSON with `hookSpecificOutput.hookEventName` set to `SessionStart` and `hookSpecificOutput.additionalContext` set to the notice text. `hooks/hooks.json` registers it as the plugin's only auto-installed hook.

- [ ] **Step 1: Write the failing test**

Create `tests/hook_notice_test.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/hook_notice_test.sh`
Expected: FAIL — `hooks/tower-version-notice.sh: No such file or directory`

- [ ] **Step 3: Write the hook**

Create `hooks/tower-version-notice.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CHECK="$ROOT/bin/tower-version-check"
if [ ! -x "$CHECK" ]; then exit 0; fi

NOTICE="$(TOWER_ROOT="$ROOT" "$CHECK" --notice 2>&1 >/dev/null || true)"
NOTICE="$(printf '%s' "$NOTICE" | tr '\n' ' ' | sed 's/[[:space:]]\{2,\}/ /g; s/^ //; s/ $//')"
if [ -z "$NOTICE" ]; then exit 0; fi

if command -v jq >/dev/null 2>&1; then
  ESCAPED="$(printf '%s' "$NOTICE" | jq -Rs .)"
else
  ESCAPED="\"$(printf '%s' "$NOTICE" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
fi

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ESCAPED"
exit 0
```

The check writes to stderr, so `2>&1 >/dev/null` captures the notice and discards stdout. Newlines are collapsed to spaces before escaping so the payload is always one JSON line.

Create `hooks/hooks.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/tower-version-notice.sh\"",
            "shell": "bash",
            "async": false,
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 4: Document it in hooks/README.md**

At the top of `hooks/README.md`, replace the opening paragraph:

```
Both hooks are copy-paste snippets (`settings-snippets.json`), installed into the **target
project's** `.claude/settings.json` — never auto-installed. Neither is load-bearing: the
protocol works without them, they just remove manual steps.
```

with:

```
One hook is auto-installed: the version notice in `hooks.json`, which ships with the plugin
and needs no setup. Every other hook here is a copy-paste snippet (`settings-snippets.json`)
installed into the **target project's** `.claude/settings.json` — never auto-installed.
None is load-bearing: the protocol works without them, they just remove manual steps.

## tower-version-notice.sh (SessionStart hook, auto-installed with the plugin)

Runs `bin/tower-version-check --notice` and, when a newer tower exists, emits the same
one-line notice as `hookSpecificOutput.additionalContext` so the session can tell its owner.
Silent when the install is current, so a current install costs no tokens. Reads only the
cache, never the network, so it cannot delay session start. Silenced by
`TOWER_NO_VERSION_CHECK=1`. Users on the `install.sh` route get this only if they add the
snippet by hand; the plugin route gets it automatically.
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `chmod +x hooks/tower-version-notice.sh && bash tests/hook_notice_test.sh`
Expected: PASS — the summary line ends `0 failed`

Run: `bash tests/run.sh`
Expected: `tests: all passed`

- [ ] **Step 6: Commit**

```bash
git add hooks/hooks.json hooks/tower-version-notice.sh hooks/README.md tests/hook_notice_test.sh
git commit -m "SessionStart hook carries the update notice into Claude sessions"
```

---

### Task 7: Release script, changelog, and the install documentation

**Files:**
- Create: `scripts/tower-release`
- Create: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `install.sh`
- Test: `tests/release_test.sh`

**Interfaces:**
- Consumes: `lib/tower-semver.sh` (`semver_gt`) and `lib/tower-meta.sh` (`tower_version`).
- Produces: `scripts/tower-release <x.y.z>`, which refuses to run on a dirty tree, on an existing tag, on a version that is not strictly newer than the manifest, on a malformed version, and when `CHANGELOG.md` has no content under `## Unreleased`. On success it rewrites the manifest version, renames the `## Unreleased` heading to `## vX.Y.Z — YYYY-MM-DD`, inserts a fresh empty `## Unreleased`, commits, tags `vX.Y.Z`, and prints the push command without running it.

- [ ] **Step 1: Write the failing test**

Create `tests/release_test.sh`:

```bash
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
assert_status "refuses a dirty tree" "$?" "1"

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/release_test.sh`
Expected: FAIL — `cp: scripts/tower-release: No such file or directory`

- [ ] **Step 3: Write the release script**

Create `scripts/tower-release`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/lib/tower-semver.sh"
. "$ROOT/lib/tower-meta.sh"

die() { echo "tower-release: $1" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: tower-release <x.y.z>"
NEW="$1"
case "$NEW" in
  [0-9]*.[0-9]*.[0-9]*) : ;;
  *) die "$NEW is not an x.y.z version" ;;
esac
case "$NEW" in *[!0-9.]*) die "$NEW is not an x.y.z version" ;; esac

MANIFEST="$ROOT/.claude-plugin/plugin.json"
CHANGELOG="$ROOT/CHANGELOG.md"
[ -r "$MANIFEST" ] || die "no manifest at $MANIFEST"
[ -r "$CHANGELOG" ] || die "no changelog at $CHANGELOG"

CURRENT="$(tower_version "$ROOT")"
[ -n "$CURRENT" ] || die "cannot read the current version from $MANIFEST"
semver_gt "$NEW" "$CURRENT" || die "$NEW is not newer than the current $CURRENT"

git -C "$ROOT" diff --quiet || die "working tree has unstaged changes"
git -C "$ROOT" diff --cached --quiet || die "working tree has staged changes"
if git -C "$ROOT" rev-parse -q --verify "refs/tags/v$NEW" >/dev/null; then
  die "tag v$NEW already exists"
fi

UNRELEASED="$(awk '/^## Unreleased$/{f=1;next} /^## /{f=0} f' "$CHANGELOG" | tr -d '[:space:]')"
[ -n "$UNRELEASED" ] || die "CHANGELOG.md has nothing under '## Unreleased' - a version bump with no entry tells nobody what shipped"

TODAY="$(date +%Y-%m-%d)"
TMP="$(mktemp)"

sed 's/"version"[[:space:]]*:[[:space:]]*"'"$CURRENT"'"/"version": "'"$NEW"'"/' "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"

TMP="$(mktemp)"
awk -v new="## v$NEW — $TODAY" '
  /^## Unreleased$/ && !done { print "## Unreleased"; print ""; print new; done=1; next }
  { print }
' "$CHANGELOG" > "$TMP"
mv "$TMP" "$CHANGELOG"

git -C "$ROOT" add "$MANIFEST" "$CHANGELOG"
git -C "$ROOT" commit -q -m "Release v$NEW"
git -C "$ROOT" tag "v$NEW"

echo "tower-release: v$NEW committed and tagged"
echo "tower-release: review, then run -> git push && git push origin v$NEW"
```

- [ ] **Step 4: Write the changelog**

Create `CHANGELOG.md`:

```markdown
# Changelog

Consumers see only a version number in the update notice, so every entry here has to say
what the version gives them.

## Unreleased

- Tower installs as a Claude Code plugin from its own marketplace, so features arrive
  through `/plugin update tower@tower` instead of a manual `git pull`.
- `tower-bootstrap` links the shell commands through a resolver shim, so a version bump
  needs no relinking.
- Installs report a newer tower once a day: a stderr line before any tower command, and a
  SessionStart note inside Claude sessions. Silence it with `TOWER_NO_VERSION_CHECK=1`.
- `.tower/` records the protocol version it was scaffolded for, and a mismatch warns.
```

- [ ] **Step 5: Document both install routes in README.md**

Replace the existing `## Install` section of `README.md` (the `git clone ... ./install.sh` block and the sentence after it) with:

````markdown
## Install

Recommended, as a Claude Code plugin:

```
/plugin marketplace add omri-am/tower
/plugin install tower@tower
/tower-bootstrap
```

The first two lines install the skills, the version-notice hook and the templates, and
Claude Code keeps them updated. `/tower-bootstrap` links the `tower-*` shell commands into
`~/.local/bin` through a resolver shim that finds the live install at call time — so
`/plugin update tower@tower` needs no relinking afterwards. Add `~/.local/bin` to your PATH
if the bootstrap says so.

Leave auto-update **off** for this marketplace. Skills changing mid-session is harmless for
a skills library; it is not harmless here, where a live orchestrator rehydrates from
`.tower/` files whose templates could change underneath it. Take updates when the notice
tells you one exists.

From a clone, which is the route for non-Claude agents:

```
git clone git@github.com:omri-am/tower.git && cd tower && ./install.sh
```

Links the three skills into `~/.claude/skills/` and prints the PATH line for `bin/`. Update
with `git pull`.

## Staying current

An install checks for a newer tagged version at most once a day, in the background, and
never blocks a command on the network. When one exists you get one line:

```
tower: 0.4.0 available (you have 0.3.1) -> /plugin update tower@tower
```

on stderr before any `tower-*` command, and as a note at the start of a Claude session.
`CHANGELOG.md` says what each version added.

- `TOWER_NO_VERSION_CHECK=1` turns the notice off.
- `TOWER_VERSION_CHECK_TTL=<seconds>` changes the check interval, default `86400`.
- `tower-version-check` run on its own checks immediately and reports either way.
````

- [ ] **Step 6: Point install.sh at the bootstrap**

At the end of `install.sh`, after the existing `case ":$PATH:"` block, append:

```bash
echo "install: for the plugin route instead, see the Install section of README.md"
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `chmod +x scripts/tower-release && bash tests/release_test.sh`
Expected: PASS — the summary line ends `0 failed`

Run: `bash tests/run.sh`
Expected: `tests: all passed`

- [ ] **Step 8: Commit**

```bash
git add scripts/tower-release CHANGELOG.md README.md install.sh tests/release_test.sh
git commit -m "Release script keeps tag and manifest in step, and the README documents both install routes"
```

---

### Task 8: Manual verification of the plugin round trip

**Files:** none. This task changes no code; it confirms the two things no bash test can reach.

**Interfaces:**
- Consumes: everything from Tasks 2 through 7.
- Produces: a recorded result. If a step fails, stop and report rather than patching blindly — a failure here means a manifest or hook assumption in the spec is wrong.

- [ ] **Step 1: Push the branch and a test tag**

```bash
git push -u origin HEAD
scripts/tower-release 0.1.1
git push && git push origin v0.1.1
```

Note: `tower-release 0.1.1` requires an entry under `## Unreleased`; Task 7 left one there.

- [ ] **Step 2: Install the plugin from the branch**

In a Claude Code session:

```
/plugin marketplace add omri-am/tower
/plugin install tower@tower
```

Expected: install succeeds, and `/plugin` lists `tower` with version `0.1.1`.

Confirm the cache path matches what the shim expects:

```bash
ls -d ~/.claude/plugins/cache/tower/tower/*/
```

Expected: a directory named for the installed version. If the path differs, the shim's
`from_cache` and the version check's `update_hint` both need correcting — report before
changing anything.

- [ ] **Step 3: Confirm the skills are namespaced as predicted**

Expected: the skill list shows `tower:tower-orchestrator`, `tower:tower-implementor` and
`tower:tower-flush`. If they appear unnamespaced, the parentheticals added in Task 2 are
harmless but unnecessary — note it, do not remove them in this task.

- [ ] **Step 4: Bootstrap and run a command**

```
/tower-bootstrap
```

Then in a shell:

```bash
export PATH="$HOME/.local/bin:$PATH"
tower-locate --quiet; echo "exit $?"
tower-version-check
```

Expected: `tower-locate` behaves as before, and `tower-version-check` prints either
`tower: 0.1.1 is current` or a notice, on stderr.

- [ ] **Step 5: Confirm the notice survives an update**

```bash
scripts/tower-release 0.1.2
git push && git push origin v0.1.2
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/tower/version-check"
tower-version-check
```

Expected: `tower: 0.1.2 available (you have 0.1.1) -> /plugin update tower@tower`.

Then run `/plugin update tower@tower` and, in the shell, `tower-version-check` again.
Expected: `tower: 0.1.2 is current`, with no re-bootstrap and no relinking.

- [ ] **Step 6: Confirm the SessionStart hook fires**

Roll the cache back so an update looks available:

```bash
printf '%s\n99.0.0\n' "$(date +%s)" > "${XDG_CACHE_HOME:-$HOME/.cache}/tower/version-check"
```

Start a fresh Claude Code session in any directory and ask it what tower version notice it
received. Expected: it reports the `99.0.0 available` line. Then delete the doctored cache.

- [ ] **Step 7: Record the outcome**

Append the results to `CHANGELOG.md` under `## Unreleased` only if a step revealed something
worth a consumer's attention. Otherwise report the results in the session and commit nothing.

---

## Self-Review

**Spec coverage:** Component 1 (manifests) is Task 2. Component 2 (skill namespacing) is Task 2 Step 4 and verified in Task 8 Step 3. Component 3 (shim and bootstrap) is Task 4. Component 4 (version check, both surfaces) is Task 3 for the check and the shell surface, Task 6 for the Claude surface. Component 5 (protocol version) is Task 5. Component 6 (release process) is Task 7. Component 7 (documentation) is spread to the task that owns each file: `PROTOCOL.md` in Task 5, `hooks/README.md` in Task 6, `README.md` and `install.sh` in Task 7. The spec's testing section maps to the test file in each task plus Task 8 for the two manual items.

**Placeholder scan:** No "TBD", "TODO", "handle errors appropriately" or "similar to Task N". Every code step carries the full file or the exact replacement text.

**Type consistency:** `semver_strip`, `semver_gt`, `semver_max` (Task 1) are used under those names in Tasks 3, 4 and 7. `tower_version`, `tower_protocol_version`, `tower_json_string` (Task 2) are used under those names in Tasks 3, 5 and 7. `--notice` is the only flag `tower-version-check` accepts, in Tasks 4 and 6 as well as 3. The environment variable names `TOWER_ROOT`, `TOWER_VERSION_REMOTE`, `TOWER_CACHE_DIR`, `TOWER_VERSION_CHECK_TTL`, `TOWER_NO_VERSION_CHECK`, `TOWER_BIN_DIR`, `TOWER_LIBEXEC_DIR` are spelled identically everywhere they appear.
