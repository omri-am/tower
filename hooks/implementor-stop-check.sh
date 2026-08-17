#!/usr/bin/env bash
set -euo pipefail

INPUT="$(cat)"

case "$INPUT" in
  *'"stop_hook_active":true'* | *'"stop_hook_active": true'*) exit 0 ;;
esac

[ -n "${TOWER_TASK:-}" ] || exit 0

PROJECT_DIR="$PWD"
while [ "$PROJECT_DIR" != "/" ] && [ ! -d "$PROJECT_DIR/.tower" ]; do
  PROJECT_DIR="$(dirname "$PROJECT_DIR")"
done
[ -d "$PROJECT_DIR/.tower" ] || exit 0
HANDOFF="$PROJECT_DIR/.tower/handoffs/$TOWER_TASK-handoff.md"

if [ -s "$HANDOFF" ]; then
  exit 0
fi

printf '{"decision": "block", "reason": "Task %s has no handoff yet. Write .tower/handoffs/%s-handoff.md from .tower/templates/handoff.md (what was done, decisions made, discoveries, follow-up tasks, candidate learnings) before finishing. Write it even if you are blocked or stopping early."}\n' "$TOWER_TASK" "$TOWER_TASK"
