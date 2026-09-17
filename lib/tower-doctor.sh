#!/usr/bin/env bash

doctor_field() {
  awk -v key="$2" '
    /^---$/ {delimiters++; next}
    delimiters==1 && index($0,key ":")==1 {
      value=substr($0,length(key)+2)
      gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", value)
      print value
      exit
    }
  ' "$1"
}

doctor_command() {
  local separator="" value
  for value in "$@"; do
    printf '%s%q' "$separator" "$value"
    separator=" "
  done
}

doctor_project_command() {
  printf 'cd %q && ' "$PROJECT_DIR"
  doctor_command "$@"
}

doctor_prepare_repository() {
  COMMON_DIR="$(doctor_common_dir "$1")"
  WORKTREES="$(git -C "$1" worktree list --porcelain)"
  PROJECT_KEY="projects/${PROJECT_DIR#"$1"/}"
  [ "$PROJECT_DIR" != "$1" ] || PROJECT_KEY=root
}

doctor_report() {
  FINDINGS=$((FINDINGS + 1))
  printf '[%s] %s: %s\n  Next: %s\n' "$1" "$2" "$3" "$4"
  if [ $# -gt 4 ]; then printf '  Command: %s\n' "$5"; fi
}

doctor_common_dir() {
  local dir
  dir="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  (cd "$dir" && pwd -P)
}

doctor_lock() {
  local state_repo="$PROJECT_DIR" lock
  [ ! -d "$PROJECT_DIR/.tower/.git" ] || state_repo="$PROJECT_DIR/.tower"
  lock="$(doctor_common_dir "$state_repo")/tower-dispatch.lock"
  [ -e "$lock" ] || return 0
  doctor_report dispatch-lock project 'dispatch lock exists; cannot determine whether it is stale' \
    "After confirming the dispatch process has stopped, remove the empty lock." \
    "$(doctor_command rmdir "$lock")"
}

doctor_handoff() {
  [ -s "$HANDOFF" ] && return 0
  doctor_report missing-handoff "$ID" "no non-empty handoff at $HANDOFF" \
    "Recover the task record and write $HANDOFF from the project handoff template." \
    "$(doctor_project_command tower-card "$ID" --plain)"
  return 1
}

doctor_pr() {
  [ -n "$(doctor_field "$CARD" pr)" ] && return 0
  local branch args=(pr list --state all)
  branch="$(doctor_field "$CARD" branch)"
  [ -z "$branch" ] || args+=(--head "$branch")
  doctor_report missing-pr "$ID" "$STATUS card has no PR reference" \
    "Find and verify the task's PR; fill the card's pr field." \
    "$(doctor_project_command gh "${args[@]}")"
}

doctor_receipt() {
  local hash receipt
  hash="$(git hash-object "$HANDOFF")"
  receipt="$(doctor_field "$CARD" ingested_handoff)"
  [ "$hash" != "$receipt" ] || return 0
  doctor_report pending-ingest "$ID" 'final handoff has not been ingested at its current revision' \
    "Have the orchestrator ingest the handoff and commit its receipt with the resulting state changes." \
    "$(doctor_project_command tower-handoffs)"
}

doctor_state_link() {
  local state="$1/.tower" resolved
  if [ ! -e "$state" ] && [ ! -L "$state" ]; then
    doctor_report missing-state "$ID" "worktree has no shared state link at $state" \
      "Restore the canonical shared state link." \
      "$(doctor_command ln -s "$PROJECT_DIR/.tower" "$state")"
    return 0
  fi
  resolved="$(cd "$state" 2>/dev/null && pwd -P)" || resolved=""
  [ "$resolved" != "$CANONICAL_STATE" ] || return 0
  doctor_report state-mismatch "$ID" "worktree state does not resolve to $CANONICAL_STATE" \
    "Inspect and preserve any local state before replacing it with a symlink to $CANONICAL_STATE." \
    "$(doctor_command ls -ld "$state")"
}

doctor_marker() {
  local marker="$1/.tower-task" task
  task="$(cat "$marker" 2>/dev/null || true)"
  [ "$task" != "$ID" ] || return 0
  doctor_report task-marker "$ID" "expected marker $marker to contain $ID, found '${task:-missing}'" \
    "Confirm the checkout belongs to $ID; then write $ID to $marker." \
    "$(doctor_command git -C "$1" branch --show-current)"
}

doctor_checkout() {
  local worktree="$1" project="$1${PROJECT_DIR#"$TOPLEVEL"}"
  if [ ! -d "$worktree" ]; then
    doctor_report missing-checkout "$ID" "registered worktree directory is missing: $worktree" \
      "Restore the checkout from disk or backup; inspect its registration before rebuilding it." \
      "$(doctor_command git -C "$TOPLEVEL" worktree list --porcelain)"
    return 0
  fi
  if [ "$(doctor_common_dir "$worktree")" != "$COMMON_DIR" ]; then
    doctor_report foreign-checkout "$ID" "registered path no longer belongs to this repository: $worktree" \
      "Inspect and preserve that repository; restore the task checkout at its registered location." \
      "$(doctor_command git -C "$worktree" rev-parse --git-common-dir)"
    return 0
  fi
  doctor_state_link "$project"
  [ "$worktree" = "$TOPLEVEL" ] || doctor_marker "$project"
}

doctor_active() {
  local branch worktree destination
  branch="$(doctor_field "$CARD" branch)"
  if [ -z "$branch" ]; then
    doctor_report missing-branch "$ID" "$STATUS card has no recorded branch" \
      "Inspect worktree registrations; record the task's actual branch in $CARD." \
      "$(doctor_command git -C "$TOPLEVEL" worktree list --porcelain)"
    return 0
  fi
  if ! git -C "$TOPLEVEL" show-ref --verify --quiet "refs/heads/$branch"; then
    doctor_report unknown-branch "$ID" "recorded branch does not exist locally: $branch" \
      "Inspect the reflog and restore the branch at its verified task commit." \
      "$(doctor_command git -C "$TOPLEVEL" reflog --all)"
    return 0
  fi
  worktree="$(printf '%s\n' "$WORKTREES" | awk -v b="refs/heads/$branch" '
    /^worktree / {path=substr($0,10)}
    $0=="branch " b {print path}
  ')"
  if [ -z "$worktree" ]; then
    destination="$(dirname "$TOPLEVEL")/$(basename "$TOPLEVEL")-tower-worktrees/$PROJECT_KEY/$ID"
    doctor_report missing-worktree "$ID" "no worktree is checked out on $branch" \
      "After checking the destination is unused, restore the branch checkout; then re-run tower-doctor." \
      "$(doctor_command git -C "$TOPLEVEL" worktree add "$destination" "$branch")"
    return 0
  fi
  doctor_checkout "$worktree"
}

doctor_merged() {
  doctor_pr
  doctor_handoff || return 0
  doctor_receipt
}

doctor_blocked() {
  doctor_report blocked "$ID" 'card is blocked' "Read the card and $HANDOFF; resolve its escalation before changing status." \
    "$(doctor_project_command tower-card "$ID" --plain)"
  doctor_handoff || true
}

doctor_review() {
  doctor_active
  doctor_pr
  doctor_handoff || true
}

doctor_status() {
  case "$STATUS" in
    draft|ready) ;;
    in-flight) doctor_active ;;
    in-review) doctor_review ;;
    merged) doctor_merged ;;
    blocked) doctor_blocked ;;
    *) doctor_report invalid-card "$ID" "unknown status '$STATUS'" "Correct the status field in $CARD using the project task-card template." ;;
  esac
}

doctor_duplicate_id() {
  local i
  for i in "${!SEEN_IDS[@]}"; do
    if [ "${SEEN_IDS[$i]}" = "$ID" ]; then
      doctor_report duplicate-id "$ID" "id $ID is carried by more than one card" \
        "Rename all but one card so the id is unique; a resolver cannot guess which one is meant." \
        "$(doctor_command ls -la "${SEEN_CARDS[$i]}" "$CARD")"
      return 0
    fi
  done
  SEEN_IDS+=("$ID")
  SEEN_CARDS+=("$CARD")
}

doctor_filename_id() {
  local base base_lc id_lc
  base="$(basename "$CARD")"
  base_lc="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
  id_lc="$(printf '%s' "$ID" | tr '[:upper:]' '[:lower:]')"
  case "$base_lc" in
    "$id_lc".md|"$id_lc"-*) return 0 ;;
  esac
  doctor_report id-filename-mismatch "$ID" "filename $base does not start with its id $ID" \
    "Rename the file to match its id, or correct the id field, so the two cannot disagree."
}

doctor_card() {
  CARD="$1"
  ID="$(doctor_field "$CARD" id)"
  STATUS="$(doctor_field "$CARD" status)"
  if [[ ! "$ID" =~ ^[Tt][0-9]+[[:alnum:]_-]*$ ]]; then
    doctor_report invalid-card "$(basename "$CARD")" 'missing or invalid task ID' \
      "Correct the id field in $CARD using the project task-card template."
    return 0
  fi
  doctor_duplicate_id
  doctor_filename_id
  HANDOFF="$PROJECT_DIR/.tower/handoffs/$ID-handoff.md"
  doctor_status
}
