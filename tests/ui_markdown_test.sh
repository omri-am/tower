#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v node >/dev/null 2>&1; then
  echo 'ui_markdown_test: node is required' >&2
  exit 1
fi
node "$ROOT/tests/ui_markdown_test.js"
