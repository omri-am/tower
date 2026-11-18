#!/usr/bin/env bash
set -u

INPUT="$(cat)"
case "$INPUT" in
  *'"notification_type":"permission_prompt"'* | *'"notification_type": "permission_prompt"'*) ;;
  *) exit 0 ;;
esac

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
LOCATED="$("$BIN_DIR/tower-locate" --quiet 2>/dev/null || true)"
PROJECT_DIR="$(printf '%s\n' "$LOCATED" | sed -n 1p)"

TASK="${TOWER_TASK:-}"
if [ -z "$TASK" ] && [ -n "$PROJECT_DIR" ]; then
  TASK="$(cat "$PROJECT_DIR/.tower-task" 2>/dev/null || true)"
fi
[ -n "$TASK" ] || exit 0

"$BIN_DIR/tower-notify" "permission prompt" "$TASK waits for your approval in its session" >/dev/null 2>&1 || true
exit 0
