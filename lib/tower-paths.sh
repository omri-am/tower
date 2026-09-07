#!/usr/bin/env bash

tower_owned_paths() {
  awk '
    /^## File ownership/ {inside=1; next}
    /^## / {inside=0}
    inside && /^- / {
      path=$2
      gsub(/`/, "", path)
      sub(/^\.\//, "", path)
      print path
    }
  ' "$1"
}

tower_path_prefix() {
  [ "$1" != . ] || return 0
  printf '%s' "$1" | sed 's/[*?[].*//'
}

tower_glob_covers() {
  case "$1" in
    *\**|*\?*|*\[*) case "$3" in "$2"*) return 0 ;; esac ;;
  esac
  return 1
}

tower_paths_overlap() {
  local left right
  left="$(tower_path_prefix "$1")"
  right="$(tower_path_prefix "$2")"
  [ -n "$left" ] && [ -n "$right" ] || return 0
  case "${right%/}/" in "${left%/}/"*) return 0 ;; esac
  case "${left%/}/" in "${right%/}/"*) return 0 ;; esac
  tower_glob_covers "$1" "$left" "$right" && return 0
  tower_glob_covers "$2" "$right" "$left" && return 0
  return 1
}
