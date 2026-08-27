#!/usr/bin/env bash

tower_json_string() {
  local file="$1" key="$2" out=""
  if [ ! -r "$file" ]; then return 0; fi
  if command -v jq >/dev/null 2>&1; then
    out="$(jq -r --arg k "$key" '.[$k] // empty' "$file" 2>/dev/null)"
  fi
  if [ -z "$out" ]; then
    out="$(tr -d '\n' < "$file" | awk -v k="\"$key\"" '
      {
        i = index($0, k)
        if (i == 0) exit
        rest = substr($0, i + length(k))
        if (match(rest, /^[[:space:]]*:[[:space:]]*"/) == 0) exit
        rest = substr(rest, RLENGTH + 1)
        j = index(rest, "\"")
        if (j == 0) exit
        print substr(rest, 1, j - 1)
      }')"
  fi
  printf '%s' "$out"
}

tower_version() {
  tower_json_string "${1:-.}/.claude-plugin/plugin.json" version
}

tower_protocol_version() {
  local file="${1:-.}/PROTOCOL_VERSION" out
  if [ ! -r "$file" ]; then return 0; fi
  out="$(head -1 "$file" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$out" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$out"
}
