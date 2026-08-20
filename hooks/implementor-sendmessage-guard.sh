#!/usr/bin/env bash
set -euo pipefail

INPUT="$(cat)"

LOCATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/tower-locate"
LOCATED="$("$LOCATE" --quiet 2>/dev/null || true)"
PROJECT_DIR="$(printf '%s\n' "$LOCATED" | sed -n 1p)"

TASK="${TOWER_TASK:-}"
if [ -z "$TASK" ] && [ -n "$PROJECT_DIR" ]; then
  TASK="$(cat "$PROJECT_DIR/.tower-task" 2>/dev/null || true)"
fi
[ -n "$TASK" ] || exit 0

TO="$(printf '%s' "$INPUT" | jq -r '.tool_input.to // empty' 2>/dev/null || true)"
ALLOWED=""
[ -n "$PROJECT_DIR" ] && ALLOWED="$(head -1 "$PROJECT_DIR/.tower/orchestrator" 2>/dev/null || true)"

if [ -n "$ALLOWED" ] && [ "$TO" = "$ALLOWED" ]; then
  exit 0
fi

printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "tower: implementor sessions escalate through files, not messages - set the card blocked, write the question into the handoff, and run tower-notify. Direct messages are allowed only to the session named in .tower/orchestrator (currently: %s)."}}\n' "${ALLOWED:-none}"
