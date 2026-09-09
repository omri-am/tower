#!/usr/bin/env bash

dispatch_die() { echo "tower-dispatch: $*" >&2; exit 1; }

dispatch_revision() {
  {
    cat "$CARD"
    printf '\0'
    if [ -f "$PROJECT_DIR/.tower/prompts/$TASK_ID-prompt.md" ]; then
      cat "$PROJECT_DIR/.tower/prompts/$TASK_ID-prompt.md"
    fi
  } | git hash-object --stdin
}

release_dispatch_lock() {
  [ -n "${DISPATCH_LOCK:-}" ] || return 0
  rmdir "$DISPATCH_LOCK"
  DISPATCH_LOCK=""
}

take_dispatch_lock() {
  local state_repo="$PROJECT_DIR"
  [ ! -d "$PROJECT_DIR/.tower/.git" ] || state_repo="$PROJECT_DIR/.tower"
  DISPATCH_LOCK="$(common_git_dir "$state_repo")/tower-dispatch.lock"
  mkdir "$DISPATCH_LOCK" 2>/dev/null || dispatch_die "dispatch is locked at $DISPATCH_LOCK; retry after the other dispatch ends (remove a stale lock only after confirming its process has stopped)"
  trap release_dispatch_lock EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

validate_ownership_paths() {
  local owned="$1" path
  [ -n "$owned" ] || dispatch_die 'File ownership must list paths as - path or - `path`'
  while IFS= read -r path; do
    case "$path" in
      /*|..|../*|*/../*|*/..|*//*|*'/./'*) dispatch_die "ownership path must be normalized and project-relative: $path" ;;
    esac
  done <<< "$owned"
}

check_owned_overlap() {
  local other="$1" path other_path other_owned
  other_owned="$(tower_owned_paths "$other")"
  validate_ownership_paths "$other_owned"
  while IFS= read -r path; do
    while IFS= read -r other_path; do
      [ -n "$other_path" ] || continue
      if tower_paths_overlap "$path" "$other_path"; then
        dispatch_die "$TASK_ID ownership $path overlaps $(basename "$other") ownership $other_path"
      fi
    done <<< "$other_owned"
  done <<< "$OWNED"
}

active_ownership_cards() {
  awk '
    FNR==1 {delimiters=0; seen=0}
    /^---$/ {delimiters++}
    delimiters==1 && /^status:/ && !seen {
      seen=1
      sub(/^status: */, "")
      if ($0 ~ /^(in-flight|in-review|blocked)$/) print FILENAME
    }
  ' "$PROJECT_DIR"/.tower/tasks/*.md
}

validate_ownership() {
  local other
  OWNED="$(tower_owned_paths "$CARD")"
  validate_ownership_paths "$OWNED"
  while IFS= read -r other; do
    [ "$other" != "$CARD" ] || continue
    check_owned_overlap "$other"
  done < <(active_ownership_cards)
}

resume_worktree() {
  [ -n "$RECORDED_BRANCH" ] || dispatch_die 'cannot resume a card without a recorded branch'
  WT="$(git -C "$TOPLEVEL" worktree list --porcelain | awk -v b="refs/heads/$RECORDED_BRANCH" '
    /^worktree / {path=substr($0,10)}
    $0=="branch " b {print path}
  ')"
  [ -n "$WT" ] || dispatch_die "no worktree remains on $RECORDED_BRANCH; restore it before resuming"
}

write_dispatch_card() {
  local tmp
  tmp="$(mktemp "$CARD.XXXXXX")"
  awk -v branch="$BRANCH" -v vendor="$VENDOR" '
    /^---$/ {delimiters++}
    delimiters==1 && /^status:/ {$0="status: in-flight"}
    delimiters==1 && /^branch:/ {$0="branch: \"" branch "\""}
    delimiters==1 && /^vendor:/ {$0="vendor: " vendor}
    {print}
  ' "$CARD" > "$tmp"
  mv "$tmp" "$CARD"
}

commit_dispatch_card() {
  local state_repo="$PROJECT_DIR"
  [ ! -d "$PROJECT_DIR/.tower/.git" ] || state_repo="$PROJECT_DIR/.tower"
  git -C "$state_repo" diff HEAD --quiet -- "$CARD" && return 0
  git -C "$state_repo" add "$CARD"
  git -C "$state_repo" commit -q --only -m "tower: dispatch $TASK_ID" -- "$CARD"
}

prepare_launch() {
  AGENT_ARGS=()
  if [ "$VENDOR" = claude ]; then
    AGENT_ARGS=(-n "$1")
    [ "$MODE" != headless ] || AGENT_ARGS+=(-p)
  elif [ "$MODE" = headless ]; then
    AGENT_ARGS=(exec)
  fi
}

launch_command() {
  local command prompt_path
  printf -v command '%q ' "$VENDOR" ${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"}
  printf -v prompt_path '%q' "$PROMPT_FILE"
  printf 'cd %q && TOWER_TASK=%q %s"$(cat %s)"' "$WORK_DIR" "$TASK_ID" "$command" "$prompt_path"
}

launch_here() {
  (cd "$WORK_DIR" && TOWER_TASK="$TASK_ID" "$VENDOR" ${AGENT_ARGS[@]+"${AGENT_ARGS[@]}"} "$(cat "$PROMPT_FILE")")
}

common_git_dir() {
  local dir
  dir="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"
  (cd "$dir" && pwd -P)
}

validate_worktree() {
  [ "$(common_git_dir "$WT")" = "$(common_git_dir "$TOPLEVEL")" ] || dispatch_die 'worktree belongs to a different repository'
  [ "$WT" != "$TOPLEVEL" ] || dispatch_die 'use --in-place explicitly to dispatch in the project checkout'
  BRANCH="$(git -C "$WT" symbolic-ref --short -q HEAD)" || dispatch_die 'worktree has a detached HEAD'
  if [ -e "$WORK_DIR/.tower" ] || [ -L "$WORK_DIR/.tower" ]; then
    [ "$(cd "$WORK_DIR/.tower" && pwd -P)" = "$(cd "$PROJECT_DIR/.tower" && pwd -P)" ] || dispatch_die 'worktree contains a different .tower state directory'
  fi
  if [ -f "$WORK_DIR/.tower-task" ]; then
    [ "$(cat "$WORK_DIR/.tower-task")" = "$TASK_ID" ] || dispatch_die 'worktree is assigned to another task'
  fi
}

prepare_in_place() {
  [ -z "$(git -C "$TOPLEVEL" status --porcelain)" ] || dispatch_die '--in-place requires a clean checkout; commit or stash changes first'
  if git -C "$TOPLEVEL" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$TOPLEVEL" checkout -q "$BRANCH"
  else
    git -C "$TOPLEVEL" checkout -q -b "$BRANCH"
  fi
}
