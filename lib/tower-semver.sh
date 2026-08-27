#!/usr/bin/env bash

semver_strip() {
  local v="${1#v}"
  printf '%s' "${v%%[-+]*}"
}

semver_gt() {
  local a b i ap bp
  a="$(semver_strip "${1:-}")"
  b="$(semver_strip "${2:-}")"
  if [ -z "$a" ] || [ -z "$b" ]; then return 2; fi
  case "$a$b" in *[!0-9.]*) return 2 ;; esac
  for i in 1 2 3; do
    ap="$(printf '%s' "$a" | cut -d. -f"$i")"
    bp="$(printf '%s' "$b" | cut -d. -f"$i")"
    ap="${ap:-0}"
    bp="${bp:-0}"
    if [ "$ap" -gt "$bp" ]; then return 0; fi
    if [ "$ap" -lt "$bp" ]; then return 1; fi
  done
  return 1
}

semver_max() {
  local best="" line
  while IFS= read -r line; do
    line="$(semver_strip "$line")"
    if [ -z "$line" ]; then continue; fi
    case "$line" in *[!0-9.]*) continue ;; esac
    if [ -z "$best" ] || semver_gt "$line" "$best"; then best="$line"; fi
  done
  printf '%s' "$best"
}
