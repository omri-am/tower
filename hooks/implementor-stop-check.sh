#!/usr/bin/env bash
set -euo pipefail

INPUT="$(cat)"

case "$INPUT" in
  *'"stop_hook_active":true'* | *'"stop_hook_active": true'*) exit 0 ;;
esac

LOCATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/tower-locate"
LOCATED="$("$LOCATE" --quiet 2>/dev/null || true)"
PROJECT_DIR="$(printf '%s\n' "$LOCATED" | sed -n 1p)"

TASK="${TOWER_TASK:-}"
if [ -z "$TASK" ] && [ -n "$PROJECT_DIR" ]; then
  TASK="$(cat "$PROJECT_DIR/.tower-task" 2>/dev/null || true)"
fi
[ -n "$TASK" ] || exit 0

if [ -z "$PROJECT_DIR" ]; then
  printf '{"decision": "block", "reason": "Task %s is in flight but no .tower/ could be located from %s. Locate the project before finishing: run tower-locate, and if it cannot resolve one, ask the owner which directory is the project root - never scaffold a new .tower/. Then write the handoff there."}\n' "$TASK" "$PWD"
  exit 0
fi

HANDOFF="$PROJECT_DIR/.tower/handoffs/$TASK-handoff.md"

if [ -s "$HANDOFF" ]; then
  exit 0
fi

printf '{"decision": "block", "reason": "Task %s has no handoff yet. Write %s from .tower/templates/handoff.md (what was done, decisions made, discoveries, follow-up tasks, candidate learnings) before finishing. Write it even if you are blocked or stopping early."}\n' "$TASK" "$HANDOFF"
