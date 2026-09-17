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

resolve_card() {
  local tasks="$1" id="$2" matches n
  matches="$(find "$tasks" -maxdepth 1 \( -iname "$id-*.md" -o -iname "$id.md" \) 2>/dev/null | sort)"
  n="$(printf '%s\n' "$matches" | grep -c .)"
  if [ "$n" -eq 0 ]; then
    echo "tower: no card for $id in $tasks" >&2
    return 1
  elif [ "$n" -gt 1 ]; then
    echo "tower: card id $id is ambiguous - $n files carry it:" >&2
    printf '  %s\n' $matches >&2
    echo "tower: rename all but one, then retry" >&2
    return 1
  fi
  printf '%s\n' "$matches"
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
