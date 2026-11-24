#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/lib.sh"
. "$ROOT/lib/tower-paths.sh"
PROJECT="$(mktemp -d)"
trap 'rm -rf "$PROJECT"' EXIT
export TOWER_NO_VERSION_CHECK=1 TOWER_ROOT="$ROOT"

if ! command -v timeout >/dev/null 2>&1; then
  timeout() {
    python3 - "$@" <<'PY'
import subprocess
import sys

try:
    sys.exit(subprocess.run(sys.argv[2:], timeout=int(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
PY
  }
fi

fixture() {
  export TOWER_PROJECT_DIR="$PROJECT/$1"
  mkdir -p "$TOWER_PROJECT_DIR/.tower/tasks"
}

card() {
  local id="$1" status="$2" track="$3"
  {
    printf '%s\n' '---' "id: $id" "status: $status"
    case "$track" in
      __missing) ;;
      __bare_empty) printf '%s\n' 'track:' ;;
      __double_quotes) printf '%s\n' 'track: ""docs""' ;;
      *) printf 'track: "%s"\n' "$track" ;;
    esac
    printf '%s\n' '---' '## File ownership' '- docs/guide.md'
  } > "$TOWER_PROJECT_DIR/.tower/tasks/$id.md"
}

charter() {
  local stem="$1" name="$2" title="$3" role="$4" approval="$5" scope="$6" path
  shift 6
  mkdir -p "$TOWER_PROJECT_DIR/.tower/tracks"
  {
    printf '%s\n' '---' "name: $name"
    [ "$title" = __missing ] || printf 'title: %s\n' "$title"
    [ "$role" = __missing ] || printf 'role: %s\n' "$role"
    [ "$approval" = __missing ] || printf 'approval: %s\n' "$approval"
    [ -z "${EXTRA_FIELD:-}" ] || printf '%s\n' "$EXTRA_FIELD"
    printf '%s\n' '---'
    [ "$scope" = __missing ] || {
      printf '%s\n' '## Scope'
      [ "$scope" = __empty ] || printf '%s\n' "$scope"
    }
    if [ "$#" -gt 0 ]; then
      printf '%s\n' '## Paths'
      for path in "$@"; do
        case "$path" in
          __none) ;;
          __bare) printf '%s\n' '-' ;;
          *) printf '%s\n' "- $path" ;;
        esac
      done
    fi
    printf '%s\n' '## Log' '- created'
  } > "$TOWER_PROJECT_DIR/.tower/tracks/$stem.md"
}

run_check() {
  "$ROOT/bin/tower-tracks" "$@" > "$PROJECT/out" 2> "$PROJECT/err"
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
within 'plain path names a directory territory' docs docs/ 0
within 'plain file does not cover suffix' lib/a.sh.bak lib/a.sh 1
within 'directory boundary' docs/agent-messaging/x.md docs/agent 1
within 'glob prefix inside a segment' lib/tower-paths.sh 'lib/tower-*.sh' 0
within 'inner glob prefix' 'docs/**/*.md' docs/ 0
within 'glob prefix ends inside a segment' 'web*' web/ 1
within 'guard: glob prefix inside the directory' 'docs/a*' docs/ 0
within 'empty glob prefix' docs/a.md '**' 0

fixture counts
charter docs docs Documentation __missing owner 'Document work' docs/
charter web web Website web-lead delegated 'Website work' web/
card T001 draft docs
card T002 ready docs
card T003 in-flight web
card T004 in-review web
card T005 merged __missing
card T006 blocked ''
card T007 unknown docs
BEFORE_TREE="$(cd "$TOWER_PROJECT_DIR" && find .tower | LC_ALL=C sort)"
BEFORE_SUMS="$(cd "$TOWER_PROJECT_DIR" && find .tower -type f -exec cksum {} + | LC_ALL=C sort)"
EXPECTED="$(printf 'docs\t1\t1\t0\t0\t0\t0\nweb\t0\t0\t1\t1\t0\t0\n-\t0\t0\t0\t0\t1\t1')"
run_check
assert_status 'counts succeed' "$STATUS" 0
assert_eq 'count rows' "$OUT" "$EXPECTED"
assert_eq 'counts stderr' "$ERR" ''
"$ROOT/bin/tower" tracks > "$PROJECT/out" 2> "$PROJECT/err"
assert_status 'front end succeeds' "$?" 0
assert_eq 'front end rows' "$(cat "$PROJECT/out")" "$EXPECTED"
assert_eq 'front end stderr' "$(cat "$PROJECT/err")" ''
AFTER_TREE="$(cd "$TOWER_PROJECT_DIR" && find .tower | LC_ALL=C sort)"
AFTER_SUMS="$(cd "$TOWER_PROJECT_DIR" && find .tower -type f -exec cksum {} + | LC_ALL=C sort)"
assert_eq 'tree unchanged' "$AFTER_TREE" "$BEFORE_TREE"
assert_eq 'file checksums unchanged' "$AFTER_SUMS" "$BEFORE_SUMS"

fixture optional-paths
charter alpha alpha Alpha '' owner 'First scope' docs/
charter beta beta Beta __missing owner 'Second scope' docs/
charter gamma gamma Gamma __missing owner 'Third scope'
card T001 ready gamma
run_check
assert_status 'optional and shared paths succeed' "$STATUS" 0
assert_eq 'optional and shared path rows' "$OUT" "$(printf 'alpha\t0\t0\t0\t0\t0\t0\nbeta\t0\t0\t0\t0\t0\t0\ngamma\t0\t1\t0\t0\t0\t0\n-\t0\t0\t0\t0\t0\t0')"
assert_eq 'optional and shared path stderr' "$ERR" ''

for KIND in name missing_title empty_title missing_approval invalid_approval role_dot role_parent role_main role_slash role_backslash delegated_role missing_scope empty_scope invalid_path unknown duplicate empty_path bare_path stem; do
  fixture "error-$KIND"
  EXTRA_FIELD=''
  STEM=docs NAME=docs TITLE=Documentation ROLE=docs-lead APPROVAL=owner SCOPE='Document work'
  PATH_VALUES=(docs/)
  case "$KIND" in
    name) NAME=other; EXPECTED_ERROR="name 'other' must equal the file stem 'docs'" ;;
    missing_title) TITLE=__missing; EXPECTED_ERROR='title is missing' ;;
    empty_title) TITLE=''; EXPECTED_ERROR='title is missing' ;;
    missing_approval) APPROVAL=__missing; EXPECTED_ERROR='approval is missing; use owner or delegated' ;;
    invalid_approval) APPROVAL=maybe; EXPECTED_ERROR="approval 'maybe' must be owner or delegated" ;;
    role_dot) ROLE=.; EXPECTED_ERROR="role '.' must not be . or .. or orchestrator, and must contain no / or \\" ;;
    role_parent) ROLE=..; EXPECTED_ERROR="role '..' must not be . or .. or orchestrator, and must contain no / or \\" ;;
    role_main) ROLE=orchestrator; EXPECTED_ERROR="role 'orchestrator' must not be . or .. or orchestrator, and must contain no / or \\" ;;
    role_slash) ROLE=a/b; EXPECTED_ERROR="role 'a/b' must not be . or .. or orchestrator, and must contain no / or \\" ;;
    role_backslash) ROLE='a\b'; EXPECTED_ERROR="role 'a\b' must not be . or .. or orchestrator, and must contain no / or \\" ;;
    delegated_role) ROLE=__missing; APPROVAL=delegated; EXPECTED_ERROR="approval 'delegated' needs a role" ;;
    missing_scope) SCOPE=__missing; EXPECTED_ERROR='## Scope is missing or empty' ;;
    empty_scope) SCOPE=__empty; EXPECTED_ERROR='## Scope is missing or empty' ;;
    invalid_path) PATH_VALUES=(docs//a.md); EXPECTED_ERROR='ownership path must be normalized and project-relative: docs//a.md' ;;
    unknown) EXTRA_FIELD='report: elsewhere'; EXPECTED_ERROR="unknown frontmatter field 'report'" ;;
    duplicate) EXTRA_FIELD='approval: owner'; EXPECTED_ERROR="frontmatter field 'approval' appears more than once" ;;
    empty_path) PATH_VALUES=(./); EXPECTED_ERROR='## Paths has an empty path' ;;
    bare_path) PATH_VALUES=(__bare); EXPECTED_ERROR='## Paths has an empty path' ;;
    stem) STEM=Docs; NAME=Docs; EXPECTED_ERROR="charter name 'Docs' must match [a-z0-9][a-z0-9-]*" ;;
  esac
  charter "$STEM" "$NAME" "$TITLE" "$ROLE" "$APPROVAL" "$SCOPE" "${PATH_VALUES[@]}"
  run_check
  assert_status "$KIND fails" "$STATUS" 1
  assert_eq "$KIND stderr" "$ERR" "tower-tracks: .tower/tracks/$STEM.md: $EXPECTED_ERROR"
  assert_eq "$KIND rows" "$OUT" "$(printf '%s\t0\t0\t0\t0\t0\t0\n-\t0\t0\t0\t0\t0\t0' "$STEM")"
done

for VALUE in nope '../tasks/x' '[a, b]'; do
  fixture "card-$VALUE"
  charter docs docs Documentation __missing owner 'Document work'
  card T001 ready "$VALUE"
  card T002 draft docs
  run_check
  assert_status "track $VALUE fails" "$STATUS" 1
  case "$VALUE" in
    nope) EXPECTED_ERROR="track 'nope' names no charter in .tower/tracks/" ;;
    *) EXPECTED_ERROR="track '$VALUE' must match [a-z0-9][a-z0-9-]*" ;;
  esac
  assert_eq "track $VALUE stderr" "$ERR" "tower-tracks: .tower/tasks/T001.md: $EXPECTED_ERROR"
  assert_eq "track $VALUE still counts" "$OUT" "$(printf 'docs\t1\t0\t0\t0\t0\t0\n-\t0\t0\t0\t0\t0\t0')"
done

fixture double-quotes
charter docs docs Documentation __missing owner 'Document work'
card T001 ready __double_quotes
run_check
assert_status 'double quoted track fails' "$STATUS" 1
assert_eq 'double quoted track stderr' "$ERR" "tower-tracks: .tower/tasks/T001.md: track '\"\"docs\"\"' must match [a-z0-9][a-z0-9-]*"
assert_eq 'double quoted track is not counted' "$OUT" "$(printf 'docs\t0\t0\t0\t0\t0\t0\n-\t0\t0\t0\t0\t0\t0')"

fixture linked-tracks
mkdir -p "$PROJECT/charters"
charter docs docs Documentation __missing owner 'Document work' docs/
mv "$TOWER_PROJECT_DIR/.tower/tracks/docs.md" "$PROJECT/charters/docs.md"
rmdir "$TOWER_PROJECT_DIR/.tower/tracks"
ln -s "$PROJECT/charters" "$TOWER_PROJECT_DIR/.tower/tracks"
card T001 ready docs
run_check
assert_status 'linked tracks directory fails' "$STATUS" 1
assert_eq 'linked tracks directory rows' "$OUT" "$(printf -- '-\t0\t0\t0\t0\t0\t0')"
assert_eq 'linked tracks directory stderr' "$ERR" "$(printf '%s\n%s' \
  'tower-tracks: .tower/tracks: is a symlink; charters are not read' \
  "tower-tracks: .tower/tasks/T001.md: track 'docs' names no charter in .tower/tracks/")"

fixture linked-charter
charter docs docs Documentation __missing owner 'Document work' docs/
mv "$TOWER_PROJECT_DIR/.tower/tracks/docs.md" "$PROJECT/charters/docs.md"
ln -s "$PROJECT/charters/docs.md" "$TOWER_PROJECT_DIR/.tower/tracks/docs.md"
run_check
assert_status 'linked charter fails' "$STATUS" 1
assert_eq 'linked charter rows' "$OUT" "$(printf 'docs\t0\t0\t0\t0\t0\t0\n-\t0\t0\t0\t0\t0\t0')"
assert_eq 'linked charter stderr' "$ERR" 'tower-tracks: .tower/tracks/docs.md: charter is a symlink'
card T001 ready docs
run_check
assert_eq 'linked charter counts named card' "$OUT" "$(printf 'docs\t0\t1\t0\t0\t0\t0\n-\t0\t0\t0\t0\t0\t0')"
assert_eq 'linked charter has no duplicate error' "$ERR" 'tower-tracks: .tower/tracks/docs.md: charter is a symlink'

fixture pipe-charter
mkdir -p "$TOWER_PROJECT_DIR/.tower/tracks"
mkfifo "$TOWER_PROJECT_DIR/.tower/tracks/docs.md"
timeout 30 "$ROOT/bin/tower-tracks" > "$PROJECT/out" 2> "$PROJECT/err"
STATUS=$?
OUT="$(cat "$PROJECT/out")"
ERR="$(cat "$PROJECT/err")"
assert_status 'pipe charter fails without timeout' "$STATUS" 1
assert_eq 'pipe charter rows' "$OUT" "$(printf 'docs\t0\t0\t0\t0\t0\t0\n-\t0\t0\t0\t0\t0\t0')"
assert_eq 'pipe charter stderr' "$ERR" 'tower-tracks: .tower/tracks/docs.md: charter is not a regular file'
card T001 ready docs
timeout 30 "$ROOT/bin/tower-tracks" > "$PROJECT/out" 2> "$PROJECT/err"
STATUS=$?
assert_status 'pipe charter with card fails without timeout' "$STATUS" 1
assert_eq 'pipe charter counts named card' "$(cat "$PROJECT/out")" "$(printf 'docs\t0\t1\t0\t0\t0\t0\n-\t0\t0\t0\t0\t0\t0')"
assert_eq 'pipe charter has no duplicate error' "$(cat "$PROJECT/err")" 'tower-tracks: .tower/tracks/docs.md: charter is not a regular file'

fixture directory-charter
mkdir -p "$TOWER_PROJECT_DIR/.tower/tracks/docs.md"
run_check
assert_status 'directory charter fails' "$STATUS" 1
assert_eq 'directory charter rows' "$OUT" "$(printf 'docs\t0\t0\t0\t0\t0\t0\n-\t0\t0\t0\t0\t0\t0')"
assert_eq 'directory charter stderr' "$ERR" 'tower-tracks: .tower/tracks/docs.md: charter is not a regular file'

fixture no-tracks
card T001 draft __missing
card T002 ready ''
EXPECTED="$(printf -- '-\t1\t1\t0\t0\t0\t0')"
run_check
assert_status 'missing directory succeeds' "$STATUS" 0
assert_eq 'missing directory row' "$OUT" "$EXPECTED"
assert_eq 'missing directory stderr' "$ERR" ''
mkdir "$TOWER_PROJECT_DIR/.tower/tracks"
run_check
assert_status 'empty directory succeeds' "$STATUS" 0
assert_eq 'empty directory row' "$OUT" "$EXPECTED"
assert_eq 'empty directory stderr' "$ERR" ''
card T003 blocked __bare_empty
run_check
assert_status 'bare empty track fails' "$STATUS" 1
assert_eq 'bare empty track stderr' "$ERR" "tower-tracks: .tower/tasks/T003.md: track '' must match [a-z0-9][a-z0-9-]*"
assert_eq 'bare empty track is not counted' "$OUT" "$EXPECTED"
run_check extra
assert_status 'arguments fail' "$STATUS" 1
assert_eq 'arguments stderr' "$ERR" 'usage: tower-tracks (no arguments)'
"$ROOT/bin/tower" territories > "$PROJECT/out" 2> "$PROJECT/err"
assert_status 'old command is gone' "$?" 127
assert_eq 'old command stderr' "$(cat "$PROJECT/err")" "tower: tower-territories is not a command in $ROOT/bin"
summary
