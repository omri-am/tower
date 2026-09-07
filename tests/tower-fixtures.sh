#!/usr/bin/env bash

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
unset TOWER_PROJECT_DIR TOWER_TASK

new_repo() {
  mkdir -p "$1"
  git init -q -b main "$1"
  git -C "$1" commit -q --allow-empty -m init
}

new_project() {
  mkdir -p "$1/.tower/tasks" "$1/.tower/prompts" "$1/.tower/handoffs"
  git init -q "$1/.tower"
  printf '.tower/\n.tower-task\n' >> "$(git -C "$1" rev-parse --path-format=absolute --git-path info/exclude)"
  git -C "$1/.tower" commit -q --allow-empty -m 'tower: init'
}

new_card() {
  local project="$1" id="$2" owned="${3:-src/$2.sh}"
  cat > "$project/.tower/tasks/$id-test.md" <<EOF
---
id: $id
title: Test $id
status: ready
depends_on: []
vendor: claude
branch: ""
pr: ""
---

## Goal
Implement $id.

## Interfaces & decisions
Preserve the interface.

## File ownership
- $owned

## Out of scope
Other files.

## Acceptance criteria
- [ ] Verification passes.

## Verification
true
EOF
  echo "Execute $id." > "$project/.tower/prompts/$id-prompt.md"
  git -C "$project/.tower" add .
  git -C "$project/.tower" commit -q -m "tower: plan $id"
}

card_field() {
  sed -n "s/^$3: *//p" "$1/.tower/tasks/$2-test.md" | tr -d '"'
}

dispatch() {
  local project="$1"; shift
  (cd "$project" && "$ROOT/bin/tower-dispatch" "$@") > "$TMP/dispatch.out" 2>&1
}
