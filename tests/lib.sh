#!/usr/bin/env bash
TESTS_RUN=0
TESTS_FAILED=0

_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL $1" >&2
}

assert_eq() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" != "$3" ]; then _fail "$1: expected [$3], got [$2]"; fi
}

assert_empty() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ -n "$2" ]; then _fail "$1: expected empty, got [$2]"; fi
}

assert_status() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" != "$3" ]; then _fail "$1: expected exit $3, got exit $2"; fi
}

assert_true() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local name="$1"; shift
  if ! "$@"; then _fail "$name: expected success from: $*"; fi
}

assert_false() {
  TESTS_RUN=$((TESTS_RUN + 1))
  local name="$1"; shift
  if "$@"; then _fail "$name: expected failure from: $*"; fi
}

summary() {
  echo "  $TESTS_RUN checks, $TESTS_FAILED failed"
  [ "$TESTS_FAILED" = 0 ]
}
