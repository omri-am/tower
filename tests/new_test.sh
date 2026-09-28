#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
PROJECT="$(mktemp -d)"
trap 'rm -rf "$PROJECT"' EXIT
export TOWER_PROJECT_DIR="$PROJECT" TOWER_NO_VERSION_CHECK=1 TOWER_ROOT="$ROOT"
TASKS="$PROJECT/.tower/tasks"
mkdir -p "$TASKS" "$PROJECT/.tower/templates"
cp "$ROOT/templates/task-card.md" "$PROJECT/.tower/templates/"
NEW="$ROOT/bin/tower-new"

printf '%s\n' '---' 'id: T011' '---' > "$TASKS/T011-old.md"
OUT="$("$ROOT/bin/tower" new 'Fix the thing' 2>"$PROJECT/error")"
assert_status 'tower new succeeds' "$?" 0
assert_eq 'next flat path' "$OUT" "$TASKS/T012-fix-the-thing.md"
if [ ! -f "$OUT" ]; then summary; exit 1; fi
sed -e 's/^id: T000$/id: T012/' -e 's/^title:$/title: Fix the thing/' \
  "$PROJECT/.tower/templates/task-card.md" > "$PROJECT/expected"
assert_true 'only id and title change in template' cmp -s "$OUT" "$PROJECT/expected"
assert_true 'claim remains' test -d "$TASKS/.claims/T012"

printf '%s\n' '---' 'id: T020' '---' 'id: T999' > "$TASKS/mismatched.md"
assert_eq 'frontmatter counts but body does not' "$("$NEW" 'Frontmatter')" "$TASKS/T021-frontmatter.md"
touch "$TASKS/T030-filename.md" "$TASKS/T900a-follow-up.md"
printf '%s\n' '---' 'id: T901b' '---' > "$TASKS/follow-up.md"
mkdir "$TASKS/.claims/T902c"
assert_eq 'filename counts and letter suffixes do not' "$("$NEW" 'Filename')" "$TASKS/T031-filename.md"
mkdir "$TASKS/.claims/T040"
assert_eq 'abandoned claim counts' "$("$NEW" 'Claim')" "$TASKS/T041-claim.md"
mkdir "$TASKS/.claims/T999"
assert_eq 'ids grow past three digits' "$("$NEW" 'Large')" "$TASKS/T1000-large.md"
TITLE='  Fix / A&B \\ path!!!  '
OUT="$("$NEW" "$TITLE")"
assert_eq 'slug normalizes punctuation' "$OUT" "$TASKS/T1001-fix-a-b-path.md"
assert_true 'title preserves shell and replacement metacharacters' grep -Fx "title: $TITLE" "$OUT"
TITLE="$(printf '%049d' 0)-tail"
assert_eq 'slug trims trailing dash after truncation' "$("$NEW" "$TITLE")" "$TASKS/T1002-$(printf '%049d' 0).md"
TITLE="$(printf 'Two\nlines')"
assert_eq 'slug collapses embedded newlines' "$("$NEW" "$TITLE")" "$TASKS/T1003-two-lines.md"
for INVALID in empty missing extra parent; do
  case "$INVALID" in
    empty) "$NEW" '' > "$PROJECT/out" 2> "$PROJECT/error" ;;
    missing) "$NEW" > "$PROJECT/out" 2> "$PROJECT/error" ;;
    extra) "$NEW" two arguments > "$PROJECT/out" 2> "$PROJECT/error" ;;
    parent) "$NEW" --parent T005 x > "$PROJECT/out" 2> "$PROJECT/error" ;;
  esac
  assert_status "rejects $INVALID title arguments" "$?" 1
  assert_true "$INVALID has error message" test -s "$PROJECT/error"
  assert_false "$INVALID prints no success path" test -s "$PROJECT/out"
done

printf '%s\n' '---' 'id: T2000' '---' > "$TASKS/unreadable.md"
chmod 000 "$TASKS/unreadable.md"
"$NEW" 'Unreadable input' > "$PROJECT/out" 2> "$PROJECT/error"
assert_status 'unreadable card aborts allocation' "$?" 1
assert_false 'unreadable card prints no success path' test -s "$PROJECT/out"
chmod 600 "$TASKS/unreadable.md"

export TOWER_PROJECT_DIR="$PROJECT/parallel"
mkdir -p "$TOWER_PROJECT_DIR/.tower/tasks" "$TOWER_PROJECT_DIR/.tower/templates"
cp "$ROOT/templates/task-card.md" "$TOWER_PROJECT_DIR/.tower/templates/"
PIDS=()
for ((i = 0; i < 20; i++)); do
  "$NEW" 'Same title' > "$PROJECT/result-$i" &
  PIDS[$i]=$!
done
for PID in "${PIDS[@]}"; do
  wait "$PID"
  assert_status 'parallel creator succeeds' "$?" 0
done
assert_eq 'parallel creators return distinct paths' "$(cat "$PROJECT"/result-* | sort -u | wc -l | tr -d ' ')" 20
assert_eq 'parallel creators write twenty cards' "$(find "$TOWER_PROJECT_DIR/.tower/tasks" -name '*.md' | wc -l | tr -d ' ')" 20
assert_eq 'parallel cards have distinct ids' "$(sed -n 's/^id: //p' "$TOWER_PROJECT_DIR"/.tower/tasks/*.md | sort -u | wc -l | tr -d ' ')" 20
assert_true 'empty project starts at T001' test -f "$TOWER_PROJECT_DIR/.tower/tasks/T001-same-title.md"
assert_true 'bootstrap links command' grep -q 'COMMANDS=.*tower-new' "$ROOT/bin/tower-bootstrap"
assert_true 'reference lists command' grep -q 'tower new' "$ROOT/docs/REFERENCE.md"
summary
