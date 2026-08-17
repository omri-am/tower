#!/usr/bin/env bash
set -euo pipefail

INPUT="$(cat)"

case "$INPUT" in
  *'"stop_hook_active":true'* | *'"stop_hook_active": true'*) exit 0 ;;
esac

[ -n "${TOWER_TASK:-}" ] || exit 0

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
HANDOFF="$REPO/.tower/handoffs/$TOWER_TASK-handoff.md"

if [ -s "$HANDOFF" ]; then
  exit 0
fi

printf '{"decision": "block", "reason": "Task %s has no handoff yet. Write .tower/handoffs/%s-handoff.md from .tower/templates/handoff.md (what was done, decisions made, discoveries, follow-up tasks, candidate learnings) before finishing. Write it even if you are blocked or stopping early."}\n' "$TOWER_TASK" "$TOWER_TASK"
