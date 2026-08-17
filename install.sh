#!/usr/bin/env bash
set -euo pipefail

TOWER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

mkdir -p "$SKILLS_DIR"
ln -sfn "$TOWER_ROOT/skills/tower-orchestrator" "$SKILLS_DIR/tower-orchestrator"
ln -sfn "$TOWER_ROOT/skills/tower-implementor" "$SKILLS_DIR/tower-implementor"
echo "install: linked tower-orchestrator and tower-implementor into $SKILLS_DIR"

chmod +x "$TOWER_ROOT/bin/tower-init" "$TOWER_ROOT/bin/tower-dispatch" "$TOWER_ROOT/bin/tower-notify" "$TOWER_ROOT/hooks/implementor-stop-check.sh"

case ":$PATH:" in
  *":$TOWER_ROOT/bin:"*) echo "install: $TOWER_ROOT/bin already on PATH" ;;
  *) echo "install: add to PATH -> export PATH=\"$TOWER_ROOT/bin:\$PATH\"" ;;
esac
