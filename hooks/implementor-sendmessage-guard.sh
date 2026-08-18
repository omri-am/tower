#!/usr/bin/env bash
set -euo pipefail

INPUT="$(cat)"

PROJECT_DIR="$PWD"
while [ "$PROJECT_DIR" != "/" ] && [ ! -d "$PROJECT_DIR/.tower" ]; do
  PROJECT_DIR="$(dirname "$PROJECT_DIR")"
done
[ -d "$PROJECT_DIR/.tower" ] || exit 0

TASK="${TOWER_TASK:-}"
[ -n "$TASK" ] || TASK="$(cat "$PROJECT_DIR/.tower-task" 2>/dev/null || true)"
[ -n "$TASK" ] || exit 0

TO="$(printf '%s' "$INPUT" | jq -r '.tool_input.to // empty' 2>/dev/null || true)"
ALLOWED="$(head -1 "$PROJECT_DIR/.tower/orchestrator" 2>/dev/null || true)"

if [ -n "$ALLOWED" ] && [ "$TO" = "$ALLOWED" ]; then
  exit 0
fi

printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "tower: implementor sessions escalate through files, not messages - set the card blocked, write the question into the handoff, and run tower-notify. Direct messages are allowed only to the session named in .tower/orchestrator (currently: %s)."}}\n' "${ALLOWED:-none}"
