#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS=0
for T in "$ROOT"/tests/*_test.sh; do
  echo "== $(basename "$T")"
  bash "$T" || STATUS=1
done
if [ "$STATUS" = 0 ]; then echo "tests: all passed"; else echo "tests: FAILURES" >&2; fi
exit "$STATUS"
