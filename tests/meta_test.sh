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

printf '{"version":"1.1.1","other":"x","version":"2.2.2"}' > "$TMP/.claude-plugin/plugin.json"
result_fallback="$(bash -c "mkdir -p $TMP/fakepath; printf '#!/bin/bash\nexit 1' > $TMP/fakepath/jq; chmod +x $TMP/fakepath/jq; export PATH=$TMP/fakepath:/usr/bin:/bin; . $ROOT/lib/tower-meta.sh; tower_json_string '$TMP/.claude-plugin/plugin.json' version")"
assert_eq "duplicate key fallback returns first value" "$result_fallback" "1.1.1"

printf '4 5\n' > "$TMP/PROTOCOL_VERSION"
assert_empty "protocol with embedded space is empty" "$(tower_protocol_version "$TMP")"

assert_eq "marketplace names the plugin tower" \
  "$(grep -c '"name": "tower"' "$ROOT/.claude-plugin/marketplace.json")" "2"
assert_eq "orchestrate prompt mentions the namespaced skill" \
  "$(grep -c 'tower:tower-orchestrator' "$ROOT/bin/tower-orchestrate")" "1"
assert_eq "orchestrator skill mentions the namespaced implementor skill" \
  "$(grep -c 'tower:tower-implementor' "$ROOT/skills/tower-orchestrator/SKILL.md")" "1"

summary
