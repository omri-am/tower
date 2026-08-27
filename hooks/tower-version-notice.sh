#!/usr/bin/env bash
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CHECK="$ROOT/bin/tower-version-check"
if [ ! -x "$CHECK" ]; then exit 0; fi

NOTICE="$(TOWER_ROOT="$ROOT" "$CHECK" --notice 2>&1 >/dev/null || true)"
NOTICE="${NOTICE//$'\n'/ | }"
NOTICE="$(printf '%s' "$NOTICE" | sed 's/[[:space:]]\{2,\}/ /g; s/^ //; s/ $//')"
if [ -z "$NOTICE" ]; then exit 0; fi

if command -v jq >/dev/null 2>&1; then
  ESCAPED="$(printf '%s' "$NOTICE" | jq -Rs .)"
else
  CLEANED="$(printf '%s' "$NOTICE" | tr '\000-\037' ' ')"
  ESCAPED="\"$(printf '%s' "$CLEANED" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
fi

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ESCAPED"
exit 0
