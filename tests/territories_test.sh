#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/lib/tower-paths.sh"
PROJECT="$(mktemp -d)"
trap 'rm -rf "$PROJECT"' EXIT
export TOWER_NO_VERSION_CHECK=1 TOWER_ROOT="$ROOT"

fixture() {
  export TOWER_PROJECT_DIR="$PROJECT/$1"
  mkdir -p "$TOWER_PROJECT_DIR/.tower/tasks"
}

card() {
  local id="$1" status="$2" path
  shift 2
  {
    printf '%s\n' '---' "id: $id" "status: $status" '---' '## File ownership'
    for path in "$@"; do printf '%s\n' "- $path"; done
  } > "$TOWER_PROJECT_DIR/.tower/tasks/$id.md"
}

charter() {
  local stem="$1" name="$2" role="$3" approval="$4" path
  shift 4
  mkdir -p "$TOWER_PROJECT_DIR/.tower/territories"
  {
    printf '%s\n' '---' "name: $name" "role: $role"
    [ "$approval" = __missing ] || printf '%s\n' "approval: $approval"
    [ -z "${EXTRA_FIELD:-}" ] || printf '%s\n' "$EXTRA_FIELD"
    printf '%s\n' '---' '## Paths'
    for path in "$@"; do
      [ "$path" = __none ] || printf '%s\n' "- $path"
    done
    printf '%s\n' '## Log' '- created'
  } > "$TOWER_PROJECT_DIR/.tower/territories/$stem.md"
}

run_check() {
  "$ROOT/bin/tower-territories" "$@" > "$PROJECT/out" 2> "$PROJECT/err"
  STATUS=$?
  OUT="$(cat "$PROJECT/out")"
  ERR="$(cat "$PROJECT/err")"
}

within() {
  tower_path_within "$2" "$3"
  assert_status "$1" "$?" "$4"
}

within 'equal path' lib/a.sh lib/a.sh 0
within 'glob directory' docs/a/b.md 'docs/**' 0
within 'trailing slash directory' docs/a.md docs/ 0
within 'plain file does not cover suffix' lib/a.sh.bak lib/a.sh 1
within 'directory boundary' docs/agent-messaging/x.md docs/agent 1
within 'glob directory boundary' docs/agent-messaging/x.md 'docs/agent*' 1
within 'inner glob prefix' 'docs/**/*.md' docs/ 0
within 'empty glob prefix' docs/a.md '**' 0

fixture assignment
charter docs docs orchestrator-docs owner docs/ docs/guide.md
charter web web orchestrator-web delegated 'web/**'
card T001 in-flight docs/guide.md changelog.d/T001.md protocol.d/T001.md reference.d/T001.md
card T002 ready docs/guide.md web/app.js
card T003 draft web/app.js bin/tool
card T004 merged changelog.d/T004.md
card T005 draft web/app.js changelog.d/T001.md
card T006 ready '`web/app.js` - explanation'
BEFORE_TREE="$(cd "$TOWER_PROJECT_DIR" && find .tower | LC_ALL=C sort)"
BEFORE_SUMS="$(cd "$TOWER_PROJECT_DIR" && find .tower -type f -exec cksum {} + | LC_ALL=C sort)"
EXPECTED="$(printf 'T001\tdocs\tin-flight\nT002\tmain\tready\nT003\tmain\tdraft\nT004\tmain\tmerged\nT005\tmain\tdraft\nT006\tweb\tready')"
run_check
assert_status 'assignment succeeds' "$STATUS" 0
assert_eq 'six assignments' "$OUT" "$EXPECTED"
assert_eq 'assignment stderr' "$ERR" ''
"$ROOT/bin/tower" territories > "$PROJECT/out" 2> "$PROJECT/err"
assert_status 'front end succeeds' "$?" 0
assert_eq 'front end assignments' "$(cat "$PROJECT/out")" "$EXPECTED"
assert_eq 'front end stderr' "$(cat "$PROJECT/err")" ''
AFTER_TREE="$(cd "$TOWER_PROJECT_DIR" && find .tower | LC_ALL=C sort)"
AFTER_SUMS="$(cd "$TOWER_PROJECT_DIR" && find .tower -type f -exec cksum {} + | LC_ALL=C sort)"
assert_eq 'tree unchanged' "$AFTER_TREE" "$BEFORE_TREE"
assert_eq 'file checksums unchanged' "$AFTER_SUMS" "$BEFORE_SUMS"

fixture overlap
charter api api orchestrator-api owner 'docs/api/**'
charter docs docs orchestrator-docs owner docs/
card T001 in-flight docs/api/x.md
run_check
assert_status 'overlap fails' "$STATUS" 1
assert_eq 'overlap stderr' "$ERR" 'tower-territories: .tower/territories/api.md: path docs/api/** overlaps .tower/territories/docs.md path docs/'
assert_eq 'overlap still assigns' "$OUT" "$(printf 'T001\tmain\tin-flight')"

for KIND in name missing_approval invalid_approval role empty_paths invalid_path unknown stem; do
  fixture "error-$KIND"
  card T001 draft docs/guide.md
  EXTRA_FIELD=''
  STEM=docs NAME=docs ROLE=orchestrator-docs APPROVAL=owner PATH_VALUE=docs/
  case "$KIND" in
    name) NAME=other; EXPECTED_ERROR="name 'other' must equal the file stem 'docs'" ;;
    missing_approval) APPROVAL=__missing; EXPECTED_ERROR='approval is missing; use owner or delegated' ;;
    invalid_approval) APPROVAL=maybe; EXPECTED_ERROR="approval 'maybe' must be owner or delegated" ;;
    role) ROLE=a/b; EXPECTED_ERROR="role 'a/b' must be nonempty, not . or .., and contain no / or \\" ;;
    empty_paths) PATH_VALUE=__none; EXPECTED_ERROR='## Paths lists no path' ;;
    invalid_path) PATH_VALUE=docs//a.md; EXPECTED_ERROR='ownership path must be normalized and project-relative: docs//a.md' ;;
    unknown) EXTRA_FIELD='report: .tower/elsewhere.md'; EXPECTED_ERROR="unknown frontmatter field 'report'" ;;
    stem) STEM=Docs NAME=Docs; EXPECTED_ERROR="charter name 'Docs' must match [a-z0-9][a-z0-9-]*" ;;
  esac
  charter "$STEM" "$NAME" "$ROLE" "$APPROVAL" "$PATH_VALUE"
  run_check
  assert_status "$KIND fails" "$STATUS" 1
  assert_eq "$KIND stderr" "$ERR" "tower-territories: .tower/territories/$STEM.md: $EXPECTED_ERROR"
done

fixture no-territories
card T001 draft docs/guide.md
card T002 ready web/app.js
EXPECTED="$(printf 'T001\tmain\tdraft\nT002\tmain\tready')"
run_check
assert_status 'missing territory directory succeeds' "$STATUS" 0
assert_eq 'missing directory assignments' "$OUT" "$EXPECTED"
assert_eq 'missing directory stderr' "$ERR" ''
mkdir "$TOWER_PROJECT_DIR/.tower/territories"
run_check
assert_status 'empty territory directory succeeds' "$STATUS" 0
assert_eq 'empty directory assignments' "$OUT" "$EXPECTED"
assert_eq 'empty directory stderr' "$ERR" ''

run_check extra
assert_status 'arguments fail' "$STATUS" 1
assert_eq 'arguments stderr' "$ERR" 'usage: tower-territories (no arguments)'
summary
